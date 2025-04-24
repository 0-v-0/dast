module dast.wsrpc;
import dast.ws.server,
lmpl4d,
std.traits;
public import dast.ws.server : PeerID, WSClient;
import core.thread,
tame.lockfree.queue;

/// A WebSocket RPC request
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
	import std.meta : Seq = AliasSeq;

	alias getActions = Seq!();
	static foreach (f; T)
		getActions = Seq!(getActions, Filter!(isCallable, getSymbolsByUDA!(f, Action)));
}

private alias
SReq = shared WSRequest,
LFQ = LockFreeQueue!SReq;

class WSRPCServer(uint pageCount, modules...) : WSServer {
	public import dast.ws : Request;
	import core.memory,
	tame.meta;

	alias AllActions = Filter!(isCallable, getSymbolsWith!(Action, modules));

	static if (pageCount) {
		LFQ queue = LFQ(SReq());

		void initWorkers(uint n) {
			auto loop = cast(EventExecutor)_loop;
			while (n--) {
				loop.queueTask(new Fiber(&mainLoop, pageCount * pageSize));
			}
		}
	}

	this(AddrFamily family = AddrFamily.IPv4) {
		static if (pageCount)
			super(new EventExecutor, family);
		else
			super(family);
	}

	this(EventLoop loop, AddrFamily family = AddrFamily.IPv4) {
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
						static if (is(attr)) {
							//pragma(msg, __traits(identifier, f));
			case __traits(identifier, f):
						} else {
							//pragma(msg, attr.name);
			case attr.name:
						}
						callAction!f(req, unpacker);
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

	pragma(inline, true)
	private void callAction(alias f)(ref WSRequest req, Unpacker!()* unpacker) {
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
}
