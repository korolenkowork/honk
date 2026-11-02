// The smallest Honk app: two routes and free docs at /docs.
//
//     goose examples/hello.goose
//     curl http://127.0.0.1:8000/
//     curl http://127.0.0.1:8000/items/5?q=geese
import honk from "../honk";

struct Message { message: const u8[:] }

struct ReadItem { item_id: i64, q: const u8[:] = "" }
struct ItemOut { item_id: i64, q: const u8[:] }

fn app(c: honk::Ctx&) {
    honk::get<Message>(c, "/") {
        Message { message: "Honk!" }
    };
    honk::get<ItemOut, ReadItem>(c, "/items/{item_id}") { p =>
        ItemOut { item_id: p.item_id, q: p.q }
    };
}

fn main() {
    honk::serve(honk::Config { port: 8000, .. }, app);
}
