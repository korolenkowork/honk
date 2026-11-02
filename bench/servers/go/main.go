// The benchmark API in Go, on its standard library (bench/README.md has the
// spec): net/http, which uses every core, and encoding/json.
//
//	cd bench/servers/go && go build -o server . && ./server
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
)

type itemIn struct {
	Name  *string  `json:"name"`
	Price *float64 `json:"price"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	body, _ := json.Marshal(v)
	w.Header().Set("content-type", "application/json")
	w.Header().Set("content-length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /hello", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"message": "Honk!"})
	})
	mux.HandleFunc("GET /items/{item_id}", func(w http.ResponseWriter, r *http.Request) {
		id, err := strconv.ParseInt(r.PathValue("item_id"), 10, 64)
		if err != nil {
			writeJSON(w, 422, map[string]any{"detail": []any{map[string]any{"type": "int_parsing", "loc": []string{"path", "item_id"}}}})
			return
		}
		writeJSON(w, 200, map[string]any{"item_id": id, "q": r.URL.Query().Get("q")})
	})
	mux.HandleFunc("POST /items", func(w http.ResponseWriter, r *http.Request) {
		var in itemIn
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.Name == nil || in.Price == nil {
			writeJSON(w, 422, map[string]any{"detail": []any{map[string]string{"type": "invalid", "msg": "name and price are required"}}})
			return
		}
		writeJSON(w, 201, map[string]any{"name": *in.Name, "price": *in.Price, "price_with_tax": *in.Price * 1.2})
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:8000", mux))
}
