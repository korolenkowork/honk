// The benchmark API in JavaScript, on Node's standard library (bench/README.md
// has the spec): node:http, one process per core through node:cluster.
//
//     node bench/servers/node/server.js
"use strict";
const cluster = require("node:cluster");
const http = require("node:http");
const os = require("node:os");

if (cluster.isPrimary) {
  for (let i = 0; i < os.availableParallelism(); i++) cluster.fork();
} else {
  const json = (res, status, value) => {
    const body = JSON.stringify(value);
    res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    res.end(body);
  };

  http.createServer((req, res) => {
    const url = new URL(req.url, "http://localhost");
    if (req.method === "GET" && url.pathname === "/hello") return json(res, 200, { message: "Honk!" });
    const item = /^\/items\/([^/]+)$/.exec(url.pathname);
    if (req.method === "GET" && item) {
      if (!/^-?\d+$/.test(item[1])) {
        return json(res, 422, { detail: [{ type: "int_parsing", loc: ["path", "item_id"] }] });
      }
      return json(res, 200, { item_id: Number(item[1]), q: url.searchParams.get("q") ?? "" });
    }
    if (req.method === "POST" && url.pathname === "/items") {
      const chunks = [];
      req.on("data", (c) => chunks.push(c));
      req.on("end", () => {
        let body;
        try { body = JSON.parse(Buffer.concat(chunks)); } catch { body = null; }
        if (!body || typeof body.name !== "string" || typeof body.price !== "number") {
          return json(res, 422, { detail: [{ type: "invalid", msg: "name and price are required" }] });
        }
        json(res, 201, { name: body.name, price: body.price, price_with_tax: body.price * 1.2 });
      });
      return;
    }
    json(res, 404, { detail: "Not Found" });
  }).listen(8000, "127.0.0.1");
}
