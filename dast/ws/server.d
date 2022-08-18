module dast.ws.server;

// dfmt off
import dast.async,
	dast.async.socket,
	std.socket,
	std.experimental.logger,
	dast.http,
	dast.ws.frame;

alias
	PeerID = int,
	ReqHandler = void function(WebSocketServer, WSClient, in Request);
// dfmt on

struct WSClient {
	TcpStream client;
	alias client this;

	@property auto id() {
		return cast(int)handle;
	}

	void send(T)(in T msg) {
		import std.traits;

		static if (isSomeString!T) {
			import std.string : representation;

			auto bytes = msg.representation;
			auto frame = Frame(true, Op.TEXT, false, State.done, [0, 0, 0, 0], msg.length, bytes);
		} else {
			alias bytes = msg;
			auto frame = Frame(true, Op.BINARY, false, State.done, [0, 0, 0, 0], msg.length, msg);
		}
		auto data = frame.serialize;
		try {
			tracef("Sending %u bytes to #%d in one frame of %u bytes long", bytes.length, id, data
					.length);
			return client.write(data);
		} catch (Exception) {
		}
	}
}

class WebSocketServer : ListenerBase {
	import dast.async.container.map;

	alias socket this;
	private size_t _bufferSize;
	protected Map!(PeerID, Frame[]) map;
	Map!(PeerID, WSClient) clients;
	ReqHandler handler;
	size_t maxConnections = 1000;

	this(AddressFamily family = AddressFamily.INET, size_t bufferSize = 4 * 1024) {
		this(new EventLoop, family, bufferSize);
	}

	this(EventLoop loop, AddressFamily family = AddressFamily.INET, size_t bufferSize = 4 * 1024) {
		_bufferSize = bufferSize;
		version (Windows)
			super(loop, family, bufferSize);
		else
			super(loop, family);
		map = new typeof(map);
		clients = new typeof(clients);
	}

	// dfmt off
	void onOpen(WSClient, Request) nothrow {}
	void onClose(WSClient) nothrow {}
	void onTextMessage(WSClient, string) nothrow {}
	void onBinaryMessage(WSClient, const(ubyte)[]) nothrow {}

	void add(TcpStream client) nothrow {
		if (clients.length > maxConnections) {
			try warningf("Maximum number of connections reached (%u)", maxConnections); catch(Exception) {}
			client.close();
		} else
			clients[WSClient(client).id] = WSClient(client);
	}

	void remove(int id) nothrow {
		map.remove(id);
		dataBySource.remove(id);
		frames.remove(id);
		if (auto client = clients[id]) {
			onClose(WSClient(client));
			try infof("Closing connection #%d", id); catch(Exception) {}
			client.close();
		}
		clients.remove(id);
	}

	// dfmt on
	void run(ushort port) {
		this.reusePort = true;
		this.bind(new InternetAddress("127.0.0.1", port));
		this.listen(128);

		infof("Listening on port: %u", port);
		infof("Maximum allowed connections: %u", maxConnections);
		start();
		(cast(EventLoop)_inLoop).run();
	}

	override void start() {
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			doAccept();
	}

	protected override void onRead() {
		//bool canRead = true;
		debug (Log)
			trace("start to listen");
		// while(canRead && isRegistered) // why??
		{
			debug (Log)
				trace("listening...");
			//canRead =
			onAccept((Socket socket) {
				debug (Log)
					infof("new connection from %s, fd=%d", socket.remoteAddress, socket.handle);

				auto client = new TcpStream(_inLoop, socket, _bufferSize);
				client.onDataReceived = (in ubyte[] data) {
					onReceive(WSClient(client), data);
				};
				client.onClosed = () { remove(WSClient(client).id); };
				client.start();
			});

			if (isError) {
				//canRead = false;
				error("listener error: ", erroString);
				close();
			}
		}
	}

	bool performHandshake(WSClient client, in ubyte[] msg, ref Request req) nothrow {
		import sha1ct : sha1Of;
		import std.conv : to;
		import std.uni : toLower;
		import tame.base64 : encode;

		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			KEY = "Sec-WebSocket-Key".toLower,
			KEY_MAXLEN = 192 - MAGIC.length;
		const(ubyte)[] data = void;
		int id = client.id;
		if (auto p = id in dataBySource)
			data = dataBySource[id] ~= msg;
		else
			data = dataBySource[id] = msg;
		if (data.length > 2048) {
			remove(id);
			return false;
		}
		if (!req.tryParse(data))
			return false;

		auto key = KEY in req.headers;
		if (!key || key.length > KEY_MAXLEN) {
			if (handler)
				try
					handler(this, client, req);
				catch (Exception) {
				}
			return false;
		}
		auto len = key.length;
		char[256] buf = void;
		buf[0 .. len] = *key;
		buf[len .. len + MAGIC.length] = MAGIC;
		try {
			client.write(
				"HTTP/1.1 101 Switching Protocol\r\n" ~
					"Upgrade: websocket\r\n" ~
					"Connection: Upgrade\r\n" ~
					"Sec-WebSocket-Accept: " ~ encode(
						sha1Of(buf[0 .. len + MAGIC.length]), buf) ~
					"\r\n\r\n");
		} catch (Exception)
			return false;
		if (map[id])
			map[id].length = 0;
		else {
			Frame[] frames;
			frames.reserve(1);
			map[id] = frames;
		}
		dataBySource[id] = [];
		return true;
	}

private nothrow:
	void onReceive(WSClient client, const scope ubyte[] data) {
		import std.algorithm : swap;

		try
			tracef("Received %u bytes from %d", data.length, client.id);
		catch (Exception) {
		}

		if (map[client.id].ptr) {
			int id = client.id;
			Frame prevFrame = id.parse(data);
			for (;;) {
				handleFrame(WSClient(client), prevFrame);
				auto newFrame = id.parse([]);
				if (newFrame == prevFrame)
					break;
				swap(newFrame, prevFrame);
			}
		} else {
			Request req;
			if (performHandshake(client, data, req)) {
				try
					infof("Handshake with %d done (path=%s)", client.id, req.path);
				catch (Exception) {
				}
				onOpen(WSClient(client), req);
			}
		}
	}

	void handleFrame(WSClient client, in Frame frame) {
		try
			tracef("From client %s received frame: done=%s; fin=%s; op=%s; length=%u",
				client.id, frame.done, frame.fin, frame.op, frame.length);
		catch (Exception) {
		}
		if (!frame.done)
			return;
		switch (frame.op) {
			// dfmt off
		case Op.CONT: return handleCont(client, frame);
		case Op.TEXT: return handle!false(client, frame);
		case Op.BINARY: return handle!true(client, frame);
		// dfmt on
		case Op.PING:
			enum pong = Frame(true, Op.PONG, false, State.done, [0, 0, 0, 0], 0, [
					]).serialize;
			try
				client.write(pong);
			catch (Exception) {
			}
			return;
		case Op.PONG:
			try
				tracef("Received pong from %s", client.id);
			catch (Exception) {
			}
			return;
		default:
			return remove(client.id);
		}
	}

	import std.array, std.format;

	void handleCont(WSClient client, in Frame frame)
	in (!client.id || map[client.id], "Client #%d is used before handshake".format(client.id)) {
		if (!frame.fin) {
			if (frame.data.length)
				map[client.id] ~= frame;
			return;
		}
		auto frames = map[client.id];
		Op originalOp = frames[0].op;
		auto data = appender!(ubyte[])();
		data.reserve(frames.length);
		foreach (f; frames)
			data ~= f.data;
		data ~= frame.data;
		map[client.id].length = 0;
		if (originalOp == Op.TEXT)
			onTextMessage(client, cast(string)data[]);
		else if (originalOp == Op.BINARY)
			onBinaryMessage(client, data[]);
	}

	void handle(bool binary)(WSClient client, in Frame frame)
	in (!map[client.id].length, "Protocol error") {
		if (frame.fin) {
			static if (binary)
				onBinaryMessage(client, frame.data);
			else
				onTextMessage(client, cast(string)frame.data);
		} else
			map[client.id] ~= frame;
	}
}
