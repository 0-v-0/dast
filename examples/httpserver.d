import dast.async;
import std.stdio;
import tame.net.socket;

extern (C) __gshared {
	bool rt_cmdline_enabled = false;
	bool rt_envvars_enabled = false;
	auto rt_options = [
		"gcopt=gc:precise", "scanDataSeg=precise"
	];
}

void main() {
	enum port = 8090;
	scope loop = new EventLoop;
	scope server = new TCPServer(loop);

	server.reusePort = true;
	const addr = IPv4Addr(IPv4Addr.loopback, port);
	server.bind(addr);
	server.listen();
	enum writeData = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n" ~
		"Content-Type: text/plain\r\n\r\nHello, World!";
	server.onAccept = (Socket socket) {
		auto client = new TCPClient(loop, socket);
		client.onReceived = (in ubyte[] data) {
			//debug writeln("received: ", cast(string)data);

			client.write(writeData);
			client.flush();
		};
		client.onClosed = {
			debug writeln("The connection is closed!");
		};
		client.onError = (in char[] msg) {
			try
				writeln("Error: ", msg);
			catch (Exception) {
			}
		};
		client.start();
	};
	server.start();

	writeln("The server is listening on ", server.localAddr);
	loop.run();
}
