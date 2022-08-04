import std.experimental.logger;

import dast.ws;

class EchoSocketServer : WebSocketServer {
	override void onOpen(WSClient client, Request req) {
		try
			tracef("Peer %s connect to '%s'", client.id, req.path);
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

class BroadcastServer : WebSocketServer {
	private string[PeerID] peers;

	override void onOpen(WSClient client, Request req) {
		peers[client.id] = req.path;
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

	override void onBinaryMessage(WSClient client, ubyte[] msg) {
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
		auto server = new EchoSocketServer;
	}
	version (broadcast) {
		pragma(msg, "broadcast");
		auto server = new BroadcastServer;
	}
	version (wshttp) {
		static void handle(WebSocketServer, WSClient client, in Request) {
			client.write("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n" ~
				"Connection: keep-alive\r\nContent-Type: text/plain\r\n\r\nHello, World!");
		}
		pragma(msg, "wshttp");
		auto server = new WebSocketServer;
		server.handler = &handle;
		server.maxConnections = 90_000;
	}

	server.run(10301);
}
