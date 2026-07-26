const http = require("node:http");

const port = Number(process.env.PORT || 3000);
http.createServer((_request, response) => {
  response.writeHead(200, {"content-type": "text/plain"});
  response.end("ok\n");
}).listen(port, "0.0.0.0");
