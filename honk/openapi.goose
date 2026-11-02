// OpenAPI. At startup Honk runs the app once with c.describing set: every
// route records its method, path, params, body and response types instead
// of matching, and the records become /openapi.json. /docs and /redoc are
// two docs pages, loading Swagger UI and ReDoc from a CDN.
namespace honk;

import std;
import exception;
import json;

// Describes App into spec, the OpenAPI 3.1 document.
fn build_openapi<App>(cfg: Config&, spec: u8[>..]&) {
    var text: u8[>..] = [];
    var routes: RouteInfo[>..] = [];
    var out: u8[>..] = [];
    var extra: u8[>..] = [];
    var scratch: u8[>..] = [];
    var api = Api { text: text, routes: routes };
    var c = Ctx { method: "", path: "", query: "", headers: "", body: "", params: [],
                  out: out, resp_headers: extra, scratch: scratch, describing: true, api: api };
    fn run() { App(c); }
    exception::try<HTTPError>(run);

    spec.append("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    json::format_string(spec, cfg.title);
    spec.append(",\"version\":");
    json::format_string(spec, cfg.version);
    if cfg.description.len > 0 {
        spec.append(",\"description\":");
        json::format_string(spec, cfg.description);
    }
    spec.append("},\"paths\":{");
    var first_path = true;
    for r, i in routes {
        let path = text[r.path_at..r.path_end];
        var earlier = false;
        for k in i { if text[routes[k].path_at..routes[k].path_end] == path { earlier = true; } }
        if earlier { continue; }
        if !first_path { spec.push(','); }
        first_path = false;
        json::format_key(spec, path);
        spec.push('{');
        var first_op = true;
        for j in i..routes.len {
            let o = routes[j];
            if text[o.path_at..o.path_end] != path { continue; }
            if !first_op { spec.push(','); }
            first_op = false;
            var m: u8[..8] = [];
            m.append(o.method);
            to_lower(m);
            json::format_key(spec, m);
            spec.append(text[o.op_at..o.op_end]);
        }
        spec.push('}');
    }
    spec.append("},\"components\":{\"schemas\":{");
    spec.append(VALIDATION_SCHEMAS);
    spec.append("}}}");
}

let VALIDATION_SCHEMAS = """
    "HTTPValidationError":{"type":"object","title":"HTTPValidationError","properties":{"detail":{"type":"array","title":"Detail","items":{"$ref":"#/components/schemas/ValidationError"}}}},"ValidationError":{"type":"object","title":"ValidationError","required":["loc","msg","type"],"properties":{"loc":{"type":"array","title":"Location","items":{"anyOf":[{"type":"string"},{"type":"integer"}]}},"msg":{"type":"string","title":"Message"},"type":{"type":"string","title":"Error Type"}}}
    """;

// Records one route: its path and its operation object.
fn describe_route<R, P>(c: Ctx&, method: const u8[:], path: u8[:], summary: const u8[:], status: i64) {
    let out = c.api.text;
    let path_at = out.len;
    out.append(path);
    let path_end = out.len;
    let op_at = out.len;
    out.push('{');
    if c.tag.len > 0 {
        out.append("\"tags\":[");
        json::format_string(out, c.tag);
        out.append("],");
    }
    if summary.len > 0 {
        out.append("\"summary\":");
        json::format_string(out, summary);
        out.push(',');
    }
    out.append("\"operationId\":\"");
    for ch in method { out.push(lower(ch)); }
    for ch in path {
        let word = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9');
        out.push(if word { ch } else { '_' });
    }
    out.append("\",\"parameters\":[");
    var p = P { .. };
    var nfields = 0;
    var nparams = 0;
    const for <N, A> in fields<P> {
        nfields++;
        describe_param(out, path, N, p.A, nparams, BY_TYPE);
    }
    out.push(']');
    const for <N, A> in fields<P> { describe_body(out, p.A, BY_TYPE); }
    format(out, ",\"responses\":{\"", status, "\":{\"description\":\"Successful Response\"");
    var r = R { .. };
    describe_response(out, r);
    out.push('}');
    if nfields > 0 {
        out.append(",\"422\":{\"description\":\"Validation Error\",\"content\":{\"application/json\":");
        out.append("{\"schema\":{\"$ref\":\"#/components/schemas/HTTPValidationError\"}}}}");
    }
    out.append("}}");
    c.api.routes.push(RouteInfo { method: method, path_at: path_at, path_end: path_end,
                                  op_at: op_at, op_end: out.len });
}

// A path or query parameter, for a scalar or string field of P.
fn describe_param(out: u8[>..]&, path: u8[:], name: const u8[:], v: i64, n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param(out: u8[>..]&, path: u8[:], name: const u8[:], v: f64, n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param(out: u8[>..]&, path: u8[:], name: const u8[:], v: bool, n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param<T>(out: u8[>..]&, path: u8[:], name: const u8[:], v: T[:], n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param<T>(out: u8[>..]&, path: u8[:], name: const u8[:], v: T[>..]&, n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param<E>(out: u8[>..]&, path: u8[:], name: const u8[:], v: Enum<E>&, n: i64&, k: i64) { param_entry(out, path, name, v, n); }
fn describe_param<T>(out: u8[>..]&, path: u8[:], name: const u8[:], v: Opt<T>&, n: i64&, k: i64) {
    if !is_model(v.value, BY_TYPE) { param_entry(out, path, name, v, n); }
}
fn describe_param<T>(out: u8[>..]&, path: u8[:], name: const u8[:], v: T&, n: i64&, k: f64) { }

fn param_entry(out: u8[>..]&, path: u8[:], name: const u8[:], v, n: i64&) {
    var key: u8[>..] = [];
    format(key, "{", name, "}");
    var rest: u8[>..] = [];
    format(rest, "{", name, ":path}");
    let in_path = find(path, key) >= 0 || find(path, rest) >= 0;
    if n > 0 { out.push(','); }
    n++;
    out.append("{\"name\":");
    json::format_string(out, name);
    out.append(if in_path { ",\"in\":\"path\",\"required\":true" } else { ",\"in\":\"query\",\"required\":false" });
    out.append(",\"schema\":");
    field_schema(out, name, v, !in_path);
    out.push('}');
}

// The request body, for a model field of P.
fn describe_body(out: u8[>..]&, v: i64, k: i64) { }
fn describe_body(out: u8[>..]&, v: f64, k: i64) { }
fn describe_body(out: u8[>..]&, v: bool, k: i64) { }
fn describe_body<T>(out: u8[>..]&, v: T[:], k: i64) { }
fn describe_body<T>(out: u8[>..]&, v: T[>..]&, k: i64) { }
fn describe_body<E>(out: u8[>..]&, v: Enum<E>&, k: i64) { }
fn describe_body<T>(out: u8[>..]&, v: Opt<T>&, k: i64) {
    if is_model(v.value, BY_TYPE) { body_entry(out, v.value, false); }
}
fn describe_body<T>(out: u8[>..]&, v: T&, k: f64) { body_entry(out, v, true); }

fn body_entry(out: u8[>..]&, v, required: bool) {
    out.append(if required { ",\"requestBody\":{\"required\":true" } else { ",\"requestBody\":{\"required\":false" });
    out.append(",\"content\":{\"application/json\":{\"schema\":");
    schema_of(out, v);
    out.append("}}}");
}

// The content of the success response, by response type.
fn describe_response(out: u8[>..]&, r: Html&) {
    out.append(",\"content\":{\"text/html\":{\"schema\":{\"type\":\"string\"}}}");
}
fn describe_response(out: u8[>..]&, r: Text&) {
    out.append(",\"content\":{\"text/plain\":{\"schema\":{\"type\":\"string\"}}}");
}
fn describe_response(out: u8[>..]&, r: Redirect&) { }
fn describe_response(out: u8[>..]&, r: NoContent&) { }
fn describe_response<T>(out: u8[>..]&, r: T&) {
    out.append(",\"content\":{\"application/json\":{\"schema\":");
    schema_of(out, r);
    out.append("}}");
}

// The /docs page: Swagger UI reading /openapi.json.
fn swagger_page(out: u8[>..]&, cfg: Config&) {
    format(out, """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui.css">
        <title>
        """, cfg.title, """
         - Swagger UI</title>
        </head>
        <body>
        <div id="swagger-ui"></div>
        <script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14/swagger-ui-bundle.js"></script>
        <script>
        SwaggerUIBundle({url: '/openapi.json', dom_id: '#swagger-ui', layout: 'BaseLayout', deepLinking: true,
          presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset]})
        </script>
        </body>
        </html>
        """);
}

// The /redoc page: ReDoc reading /openapi.json.
fn redoc_page(out: u8[>..]&, cfg: Config&) {
    format(out, """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>
        """, cfg.title, """
         - ReDoc</title>
        <style>body { margin: 0; padding: 0; }</style>
        </head>
        <body>
        <redoc spec-url="/openapi.json"></redoc>
        <script src="https://cdn.jsdelivr.net/npm/redoc@2.1.5/bundles/redoc.standalone.js"></script>
        </body>
        </html>
        """);
}
