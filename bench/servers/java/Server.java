// The benchmark API in Java, on the JDK alone (bench/README.md has the spec):
// com.sun.net.httpserver with a virtual thread per request. The JDK has no
// JSON library, so the request body is read with a small hand-written scan.
//
//     javac -d bench/servers/java/out bench/servers/java/Server.java
//     java -cp bench/servers/java/out Server
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Server {
    private static final Pattern NAME = Pattern.compile("\"name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
    private static final Pattern PRICE = Pattern.compile("\"price\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?(?:[eE][-+]?\\d+)?)");
    private static final Pattern INT = Pattern.compile("-?\\d+");

    public static void main(String[] args) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 8000), 1024);
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/", Server::handle);
        server.start();
    }

    private static void handle(HttpExchange ex) throws IOException {
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getRawPath();
        if (method.equals("GET") && path.equals("/hello")) {
            send(ex, 200, "{\"message\":\"Honk!\"}");
        } else if (method.equals("GET") && path.startsWith("/items/")) {
            String id = path.substring(7);
            if (!INT.matcher(id).matches()) {
                send(ex, 422, "{\"detail\":[{\"type\":\"int_parsing\",\"loc\":[\"path\",\"item_id\"]}]}");
                return;
            }
            send(ex, 200, "{\"item_id\":" + Long.parseLong(id) + ",\"q\":\"" + escape(query(ex, "q")) + "\"}");
        } else if (method.equals("POST") && path.equals("/items")) {
            String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            Matcher name = NAME.matcher(body);
            Matcher price = PRICE.matcher(body);
            if (!name.find() || !price.find()) {
                send(ex, 422, "{\"detail\":[{\"type\":\"invalid\",\"msg\":\"name and price are required\"}]}");
                return;
            }
            double p = Double.parseDouble(price.group(1));
            send(ex, 201, "{\"name\":\"" + name.group(1) + "\",\"price\":" + p + ",\"price_with_tax\":" + (p * 1.2) + "}");
        } else {
            send(ex, 404, "{\"detail\":\"Not Found\"}");
        }
    }

    private static String query(HttpExchange ex, String key) {
        String raw = ex.getRequestURI().getRawQuery();
        if (raw == null) return "";
        for (String pair : raw.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && pair.substring(0, eq).equals(key)) {
                return URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
            }
        }
        return "";
    }

    private static String escape(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static void send(HttpExchange ex, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("content-type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = ex.getResponseBody()) {
            out.write(bytes);
        }
    }
}
