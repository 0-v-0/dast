import dast.http.server;

void handle(HTTPServer server, HTTPClient client, scope NextHandler next) {
	client.writeHeader("HTTP/1.1 " ~ Status.OK);
	client.writeHeader("Content-Type: text/html; charset=UTF-8");
	client.writeHeader("Connection: keep-alive");
	client.send("<h1>Hello world</h1>");
	next();
}

void main() {
	scope loop = new EventLoop;
	scope server = new HTTPServer(loop);
	server.settings.listen = "127.0.0.1:8080";
	server.use(&handle);
	server.run();
}
