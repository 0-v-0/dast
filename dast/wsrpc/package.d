module dast.wsrpc;
import dast.ws.server,
lmpl4d,
std.traits;
public import dast.ws.server : PeerID, WSClient;

version (APIDoc) {
} else {
	version = Server;
	import core.thread,
	lockfree.queue;
}

struct WSRequest {
	WSClient src;
	Unpacker!() unpacker;
	Packer!() packer;
	ubyte[] buf;
	alias unpacker this;

	auto send(T...)(auto ref T data) => packer.pack(data);

	auto read(T)() => unpacker.unpack!T;

	auto read(T...)(auto ref T data) => unpacker.unpack(data);

	@property OK() {
		string err;
		return read(err) || err == "";
	}

	void reverse() nothrow {
		unpacker = Unpacker!()(packer.buf);
		packer.buf.length = 0;
	}

	bool call(alias fn, A...)(auto ref const A args) if (isCallable!fn) {
		static if (A.length)
			send(args);
		reverse();
		fn(this);
		reverse();
		return OK;
	}
}

struct Action {
	string name;
}

/// get all functions with @Action
template getActions(T...) {
	import std.meta;

	alias getActions = AliasSeq!();
	static foreach (f; T)
		getActions = AliasSeq!(getActions, Filter!(isCallable, getSymbolsByUDA!(f, Action)));
}

version (Server)  : private alias
SReq = shared WSRequest,
LFQ = LockFreeQueue!SReq;

class WSRPCServer(uint pageCount, T...) : WebSocketServer {
	public import dast.ws : Request;
	import core.memory,
	std.socket;

	alias AllActions = getActions!T;

	static if (pageCount) {
		LFQ queue = LFQ(SReq());

		void initWorkers(uint n) {
			auto loop = cast(FiberEventLoop)_inLoop;
			while (n--) {
				loop.queueTask(new Fiber(&mainLoop, pageCount * pageSize));
			}
		}
	}

	this(AddressFamily family = AddressFamily.INET) {
		static if (pageCount)
			super(new FiberEventLoop, family);
		else
			super(family);
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		super(loop, family);
	}

	override void onBinaryMessage(WSClient src, const(ubyte)[] msg) {
		auto req = WSRequest(src, unpacker(msg));
		static if (pageCount)
			queue.enqueue(cast(shared)req);
		else
			handleRequest(req);
	}

	static if (pageCount)
		noreturn mainLoop() {
			for (;;) {
				SReq req = void;
				while (!queue.dequeue(req))
					Fiber.yield();
				handleRequest(cast()req);
			}
		}

	void handleRequest(ref WSRequest req) nothrow {
		auto unpacker = &req.unpacker;
		req.packer = packer(req.buf);
		uint id = void;
		scope (exit)
			req.buf.length = 0;
		try
			req.send(id = unpacker.unpack!uint, null);
		catch (Exception e) {
			try
				req.src.send(e.toString());
			catch (Exception) {
			}
			return;
		}
		try {
			// 调用字符串action对应的带@Action的函数
			auto action = unpacker.unpack!string;
		s:
			switch (action) {
				static foreach (f; AllActions) {
					static foreach (attr; getUDAs!(f, Action)) {
						static if (__traits(compiles, (string s) { s = attr.name; })) {
							//pragma(msg, attr.name);
			case attr.name:
						} else {
							//pragma(msg, __traits(identifier, f));
			case __traits(identifier, f):
						}
						{
							alias P = Parameters!f;
							static if (P.length) {
								enum r = is(Unqual!(P[0]) == WSRequest);
								static assert(!r || (ParameterStorageClassTuple!f[0] & ParameterStorageClass.ref_),
									`The first parameter of Action "` ~ fullyQualifiedName!f ~ "\" must be `ref`");
								P[r .. $] p = void;
								foreach (i, ref x; p)
									static if (is(ParameterDefaults!f[i + r] == void))
										x = unpacker.unpack!(P[i + r]);
									else static if (isArray!(P[i + r])) {
										x = ParameterDefaults!f[i + r];
										unpacker.unpack(x);
									} else
										x = unpacker.unpack(ParameterDefaults!f[i + r]);
								static if (r)
									f(req, p);
								else
									f(p);
							} else
								f();
						}
						break s;
					}
				}
			default:
				throw new Exception(`Unknown action "` ~ action ~ '"');
			}
		} catch (Exception e) {
			req.buf.length = 0;
			req.send(id, e.msg);
		}
		req.src.send(req.packer[]);
	}
}
