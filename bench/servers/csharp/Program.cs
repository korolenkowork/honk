// The benchmark API in C#, on ASP.NET Core, which ships with the .NET SDK
// (bench/README.md has the spec): Kestrel, minimal APIs and System.Text.Json.
//
//     dotnet publish bench/servers/csharp -c Release -o bench/servers/csharp/out
//     bench/servers/csharp/out/server
using System.Text.Json;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.WebHost.UseUrls("http://127.0.0.1:8000");
var app = builder.Build();

app.MapGet("/hello", () => Results.Json(new { message = "Honk!" }));

app.MapGet("/items/{item_id}", (string item_id, string? q) =>
    long.TryParse(item_id, out var id)
        ? Results.Json(new { item_id = id, q = q ?? "" })
        : Results.Json(new { detail = new[] { new { type = "int_parsing", loc = new[] { "path", "item_id" } } } },
                       statusCode: 422));

app.MapPost("/items", async (HttpRequest request) =>
{
    try
    {
        using var doc = await JsonDocument.ParseAsync(request.Body);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Object &&
            root.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String &&
            root.TryGetProperty("price", out var price) && price.ValueKind == JsonValueKind.Number)
        {
            var p = price.GetDouble();
            return Results.Json(new { name = name.GetString(), price = p, price_with_tax = p * 1.2 }, statusCode: 201);
        }
    }
    catch (JsonException) { }
    return Results.Json(new { detail = new[] { new { type = "invalid", msg = "name and price are required" } } },
                        statusCode: 422);
});

app.Run();
