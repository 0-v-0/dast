import dast.http.server;
import std.socket;

void handle(HTTPServer server, HTTPClient client, in Request req, scope NextHandler next) {
	client.writeHeader("HTTP/1.1 200 OK");
	client.writeHeader("Content-Type: text/html; charset=UTF-8");
	client.writeHeader("Connection: keep-alive");
	client.send("<h1>Hello world</h1>");
}

void main() {
	import std.parallelism;

	scope loop = new EventLoop;
	scope server = new HTTPServer(loop);
	server.settings.address = "127.0.0.1:8080";
	server.use(&handle);
	server.run();
}
