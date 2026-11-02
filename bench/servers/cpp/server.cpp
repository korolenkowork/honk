// The benchmark API in C++ (bench/README.md has the spec). The C++ standard
// library has no HTTP or JSON, so this is a minimal hand-written server: a
// std::thread per connection, HTTP/1.1 keep-alive, and just enough JSON to
// read {"name": "...", "price": ...}.
//
//     c++ -std=c++20 -O2 -pthread bench/servers/cpp/server.cpp -o bench/servers/cpp/server
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

#include <charconv>
#include <csignal>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <thread>

namespace {

bool send_all(int fd, std::string_view s) {
    while (!s.empty()) {
        ssize_t w = send(fd, s.data(), s.size(), 0);
        if (w <= 0) return false;
        s.remove_prefix(static_cast<size_t>(w));
    }
    return true;
}

bool respond(int fd, int status, std::string_view reason, std::string_view body) {
    std::string out = "HTTP/1.1 " + std::to_string(status) + " " + std::string(reason) +
                      "\r\ncontent-type: application/json\r\ncontent-length: " +
                      std::to_string(body.size()) + "\r\n\r\n";
    out += body;
    return send_all(fd, out);
}

// The text after "key": in a flat JSON object.
std::optional<std::string_view> json_value(std::string_view body, std::string_view key) {
    std::string pattern = "\"" + std::string(key) + "\"";
    size_t at = body.find(pattern);
    if (at == std::string_view::npos) return std::nullopt;
    body.remove_prefix(at + pattern.size());
    while (!body.empty() && (body[0] == ' ' || body[0] == '\t' || body[0] == '\n' || body[0] == '\r')) body.remove_prefix(1);
    if (body.empty() || body[0] != ':') return std::nullopt;
    body.remove_prefix(1);
    while (!body.empty() && (body[0] == ' ' || body[0] == '\t' || body[0] == '\n' || body[0] == '\r')) body.remove_prefix(1);
    return body;
}

std::string number(double v) {
    char buf[32];
    auto [end, ec] = std::to_chars(buf, buf + sizeof buf, v);   // shortest round-trip form
    return std::string(buf, end);
}

bool create_item(int fd, std::string_view body) {
    auto name = json_value(body, "name");
    auto price = json_value(body, "price");
    double v = 0;
    bool ok = name && !name->empty() && (*name)[0] == '"' && price;
    if (ok) {
        auto [end, ec] = std::from_chars(price->data(), price->data() + price->size(), v);
        ok = ec == std::errc();
    }
    size_t close_quote = ok ? name->find('"', 1) : std::string_view::npos;
    if (!ok || close_quote == std::string_view::npos) {
        return respond(fd, 422, "Unprocessable Content",
                       R"({"detail":[{"type":"invalid","msg":"name and price are required"}]})");
    }
    std::string out = "{\"name\":\"" + std::string(name->substr(1, close_quote - 1)) + "\",\"price\":" +
                      number(v) + ",\"price_with_tax\":" + number(v * 1.2) + "}";
    return respond(fd, 201, "Created", out);
}

bool route(int fd, std::string_view method, std::string_view target, std::string_view body) {
    std::string_view query;
    if (size_t q = target.find('?'); q != std::string_view::npos) {
        query = target.substr(q + 1);
        target = target.substr(0, q);
    }
    if (method == "GET" && target == "/hello") return respond(fd, 200, "OK", R"({"message":"Honk!"})");
    if (method == "GET" && target.starts_with("/items/")) {
        std::string_view digits = target.substr(7);
        long long id = 0;
        auto [end, ec] = std::from_chars(digits.data(), digits.data() + digits.size(), id);
        if (digits.empty() || ec != std::errc() || end != digits.data() + digits.size()) {
            return respond(fd, 422, "Unprocessable Content",
                           R"({"detail":[{"type":"int_parsing","loc":["path","item_id"]}]})");
        }
        std::string_view q;
        while (!query.empty()) {
            size_t amp = query.find('&');
            std::string_view pair = query.substr(0, amp);
            if (pair.starts_with("q=")) q = pair.substr(2);
            query = amp == std::string_view::npos ? std::string_view() : query.substr(amp + 1);
        }
        return respond(fd, 200, "OK", "{\"item_id\":" + std::to_string(id) + ",\"q\":\"" + std::string(q) + "\"}");
    }
    if (method == "POST" && target == "/items") return create_item(fd, body);
    return respond(fd, 404, "Not Found", R"({"detail":"Not Found"})");
}

size_t content_length(std::string_view head) {
    size_t at = 0;
    while ((at = head.find("\r\n", at)) != std::string_view::npos) {
        at += 2;
        std::string_view line = head.substr(at, head.find("\r\n", at) - at);
        if (line.size() > 15) {
            std::string name(line.substr(0, 15));
            for (auto &ch : name) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
            if (name == "content-length:") {
                std::string_view v = line.substr(15);
                while (!v.empty() && v[0] == ' ') v.remove_prefix(1);
                size_t n = 0;
                std::from_chars(v.data(), v.data() + v.size(), n);
                return n;
            }
        }
    }
    return 0;
}

void serve(int fd) {
    std::string buf;
    char chunk[16384];
    for (;;) {
        size_t head_end;
        while ((head_end = buf.find("\r\n\r\n")) == std::string::npos) {
            if (buf.size() > 65536) return;
            ssize_t n = recv(fd, chunk, sizeof chunk, 0);
            if (n <= 0) return;
            buf.append(chunk, static_cast<size_t>(n));
        }
        std::string_view head(buf.data(), head_end);
        size_t total = head_end + 4 + content_length(head);
        while (buf.size() < total) {
            ssize_t n = recv(fd, chunk, sizeof chunk, 0);
            if (n <= 0) return;
            buf.append(chunk, static_cast<size_t>(n));
        }
        std::string_view line = head.substr(0, head.find("\r\n"));
        size_t sp1 = line.find(' '), sp2 = line.find(' ', sp1 + 1);
        if (sp1 == std::string_view::npos || sp2 == std::string_view::npos) return;
        std::string_view body(buf.data() + head_end + 4, total - head_end - 4);
        if (!route(fd, line.substr(0, sp1), line.substr(sp1 + 1, sp2 - sp1 - 1), body)) return;
        buf.erase(0, total);
    }
}

}  // namespace

int main() {
    std::signal(SIGPIPE, SIG_IGN);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8000);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, reinterpret_cast<sockaddr *>(&addr), sizeof addr) || listen(listener, 1024)) {
        std::perror("listen");
        return 1;
    }
    for (;;) {
        int fd = accept(listener, nullptr, nullptr);
        if (fd < 0) continue;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        std::thread([fd] { serve(fd); close(fd); }).detach();
    }
}
