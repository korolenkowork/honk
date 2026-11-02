// A CRUD API: request and response
// models, validation, path/query/body params, an enum, partial updates with
// honk::Opt, HTTP errors, a router with a prefix, a dependency and an HTML
// page. The items live in a global array.
//
//     goose examples/items.goose
//     open http://127.0.0.1:8000/docs
import honk from "../honk";
import std;

// ---------------------------------------------------------------- models

struct Dimensions { width: f64, height: f64 }

// Sent and answered as "Tool", "Toy" or "Food".
enum Category { Tool, Toy, Food }

// What a client sends to create an item. tax and in_stock have defaults,
// so they may be left out; the rest are required.
struct ItemIn {
    name: u8[..32],
    description: u8[..128] = "No description",
    price: f64,
    tax: f64 = 0.2,
    in_stock: bool = true,
    category: honk::Enum<Category>,
    size: Dimensions,
}

// A partial update: only the fields the client sends change.
struct ItemPatch { name: honk::Opt<u8[..32]>, price: honk::Opt<f64>, in_stock: honk::Opt<bool> }

// What the API answers with.
struct Item {
    id: i64,
    name: u8[..32],
    description: u8[..128],
    price: f64,
    price_with_tax: f64,
    in_stock: bool,
    category: honk::Enum<Category>,
    size: Dimensions,
}

struct ItemList { total: i64, items: Item[>..] }
struct Deleted { deleted: i64 }

// Params structs: fields named in the path come from the path, model
// fields from the JSON body, the rest from the query string.
struct ListItems { skip: i64 = 0, limit: i64 = 10, q: const u8[:] = "" }
struct ItemId { item_id: i64 }
struct CreateItem { item: ItemIn }
struct UpdateItem { item_id: i64, item: ItemIn }
struct PatchItem { item_id: i64, patch: ItemPatch }

struct User { username: const u8[:], admin: bool }

// ---------------------------------------------------------------- storage

var items: Item[>..<] = [];   // grow-shrink: rows can be removed
var next_id = 1;

fn store(id: i64, it: ItemIn&) -> Item {
    Item { id: id, name: it.name, description: it.description, price: it.price,
           price_with_tax: it.price * (1.0 + it.tax), in_stock: it.in_stock, category: it.category,
           size: it.size }
}

fn find_item(id: i64) -> i64 {
    for x, i in items { if x.id == id { return i; } }
    honk::raise(404, "Item not found");
}

// A dependency: an ordinary function the handlers
// call. It answers 401 itself when the token is wrong.
fn current_user(c: honk::Ctx&) -> User {
    let token, sent = honk::header(c, "x-token");
    guard sent && token == "secret-goose" else { honk::raise(401, "Invalid X-Token header"); }
    return User { username: "goose", admin: true };
}

// ---------------------------------------------------------------- routes

fn item_routes(c: honk::Ctx&) {
    honk::get<ItemList, ListItems>(c, "", "List items") { p =>
        var page = ItemList { total: 0, items: [] };
        for &x in items {
            if p.q.len > 0 && find(x.name, p.q) < 0 { continue; }
            if page.total >= p.skip && page.items.len < p.limit { page.items.push(x); }
            page.total++;
        }
        page
    };

    honk::post<Item, CreateItem>(c, "", "Create an item", 201) { p =>
        if p.item.price <= 0.0 { honk::raise(400, "price must be positive"); }
        let id = next_id;
        next_id++;
        items.push(store(id, p.item));
        store(id, p.item)
    };

    honk::get<Item, ItemId>(c, "/{item_id}", "Read an item") { p =>
        items[find_item(p.item_id)]
    };

    honk::put<Item, UpdateItem>(c, "/{item_id}", "Replace an item") { p =>
        let i = find_item(p.item_id);
        items[i] = store(p.item_id, p.item);
        items[i]
    };

    honk::patch<Item, PatchItem>(c, "/{item_id}", "Update some fields of an item") { p =>
        let i = find_item(p.item_id);
        if p.patch.name.set { items[i].name = p.patch.name.value; }
        if p.patch.price.set {
            items[i].price_with_tax = items[i].price_with_tax / items[i].price * p.patch.price.value;
            items[i].price = p.patch.price.value;
        }
        if p.patch.in_stock.set { items[i].in_stock = p.patch.in_stock.value; }
        items[i]
    };

    honk::delete<Deleted, ItemId>(c, "/{item_id}", "Delete an item") { p =>
        let user = current_user(c);
        let i = find_item(p.item_id);
        remove_at(items, i);
        Deleted { deleted: p.item_id }
    };
}

fn app(c: honk::Ctx&) {
    honk::get<honk::Html>(c, "/", "Home page") {
        honk::Html { body: str("<h1>Honk!</h1><p>", items.len, " items. See <a href=\"/docs\">/docs</a>.</p>") }
    };
    honk::get<User>(c, "/users/me", "Who am I") {
        current_user(c)
    };
    honk::include(c, "/items", "items", item_routes);
}

fn main() {
    let a = ItemIn { name: "Goose feather", price: 2.5, category: honk::Enum<Category> { Category.Tool },
                     size: Dimensions { 1.0, 10.0 }, .. };
    let b = ItemIn { name: "Honk horn", description: "Very loud", price: 15.0,
                     category: honk::Enum<Category> { Category.Toy }, size: Dimensions { 4.0, 4.0 }, .. };
    items.push(store(next_id, a)); next_id++;
    items.push(store(next_id, b)); next_id++;
    honk::serve(honk::Config { title: "Items API", description: "A CRUD API in Goose", .. }, app);
}
