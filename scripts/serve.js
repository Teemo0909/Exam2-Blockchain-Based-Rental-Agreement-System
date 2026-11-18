// Static server for docs/ (MetaMask does not inject into file:// pages).
const http = require("http");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "../docs");
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".json": "application/json" };
const port = process.env.PORT || 5173;

http.createServer((req, res) => {
  const url = req.url.split("?")[0];
  const file = path.join(root, url === "/" ? "index.html" : path.normalize(url));
  if (!file.startsWith(root)) return res.writeHead(403).end();
  fs.readFile(file, (err, data) => {
    if (err) return res.writeHead(404).end("not found");
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream" }).end(data);
  });
}).listen(port, () => console.log(`UI: http://localhost:${port}`));
