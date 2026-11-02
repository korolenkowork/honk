// The benchmark API in Honk (bench/README.md has the spec), on every core.
//
//     goose build bench/servers/honk/server.goose && bench/servers/honk/server
import honk from "../../../honk";

struct Hello { message: const u8[:] }

struct ReadItem { item_id: i64, q: const u8[:] = "" }
struct ItemOut { item_id: i64, q: const u8[:] }

struct ItemIn { name: const u8[:], price: f64 }
struct CreateItem { item: ItemIn }
struct Created { name: const u8[:], price: f64, price_with_tax: f64 }

fn app(c: honk::Ctx&) {
    honk::get<Hello>(c, "/hello") { Hello { message: "Honk!" } };
    honk::get<ItemOut, ReadItem>(c, "/items/{item_id}") { p => ItemOut { item_id: p.item_id, q: p.q } };
    honk::post<Created, CreateItem>(c, "/items", "", 201) { p =>
        Created { name: p.item.name, price: p.item.price, price_with_tax: p.item.price * 1.2 }
    };
}

let CONFIG = honk::Config { host: "127.0.0.1", port: 8000, log: false, .. };

thread_fn worker(fd: i64, id: i64) { honk::serve_on(fd, id, CONFIG, app); }

fn main() { honk::serve_threads(CONFIG, 0, worker); }
