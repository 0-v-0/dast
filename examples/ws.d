import std.logger;

import dast.ws;

class EchoServer : WSServer {
	override void onOpen(WSClient client, in Request req) {
		try
			trace("Peer ", client.id, " connect to '", req.path, "'");
		catch (Exception) {
		}
	}

	override void onTextMessage(WSClient client, string msg) {
		try {
			client.send(msg);
		} catch (Exception) {
		}
	}
}

class BroadcastServer : WSServer {
	private const(char)[][PeerID] peers;
	WSClient[PeerID] clients;

	override void onOpen(WSClient client, in Request req) {
		peers[client.id] = req.path;
		clients[client.id] = client;
	}

	override void onClose(WSClient client) {
		peers.remove(client.id);
	}

	override void onTextMessage(WSClient client, string msg) {
		auto src = client.id;
		auto srcPath = peers[src];
		try {
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					clients[id].send(msg);
		} catch (Exception) {
		}
	}

	override void onBinaryMessage(WSClient client, const(ubyte)[] msg) {
		auto src = client.id;
		auto srcPath = peers[src];
		try {
			foreach (id, path; peers)
				if (id != src && path == srcPath)
					clients[id].send(msg);
		} catch (Exception) {
		}
	}
}

void main() {
	version (echo) {
		pragma(msg, "echo");
		auto server = new EchoServer;
	}
	version (broadcast) {
		pragma(msg, "broadcast");
		auto server = new BroadcastServer;
	}
	version (wshttp) {
		static void handle(WSServer, WSClient client, in Request) {
			client.write("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n" ~
				"Connection: keep-alive\r\nContent-Type: text/plain\r\n\r\nHello, World!");
		}
		pragma(msg, "wshttp");
		auto server = new WSServer;
		server.handler = &handle;
		server.settings.maxConnections = 90_000;
	}
	server.settings.listen = ":10301";
	server.run();
}
