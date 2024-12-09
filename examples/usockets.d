import dast.usockets;
import core.stdc.stdio;
import core.sync;
import core.thread;

uint totalCPUs() @nogc nothrow @trusted {
	version (Windows) {
		// NOTE: Only works on Windows 2000 and above.
		import core.sys.windows.winbase : SYSTEM_INFO, GetSystemInfo;
		import std.algorithm.comparison : max;

		SYSTEM_INFO si;
		GetSystemInfo(&si);
		return max(1, cast(uint)si.dwNumberOfProcessors);
	} else version (linux) {
		import core.stdc.stdlib : calloc;
		import core.stdc.string : memset;
		import core.sys.linux.sched : CPU_ALLOC_SIZE, CPU_FREE, CPU_COUNT, CPU_COUNT_S, cpu_set_t, sched_getaffinity;
		import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

		int count = 0;

		/**
		 * According to ruby's source code, CPU_ALLOC() doesn't work as expected.
		 *  see: https://github.com/ruby/ruby/commit/7d9e04de496915dd9e4544ee18b1a0026dc79242
		 *
		 *  The hardcode number also comes from ruby's source code.
		 *  see: https://github.com/ruby/ruby/commit/0fa75e813ecf0f5f3dd01f89aa76d0e25ab4fcd4
		 */
		for (int n = 64; n <= 16384; n *= 2) {
			size_t size = CPU_ALLOC_SIZE(count);
			if (size >= 0x400) {
				auto cpuset = cast(cpu_set_t*)calloc(1, size);
				if (cpuset is null)
					break;
				if (sched_getaffinity(0, size, cpuset) == 0) {
					count = CPU_COUNT_S(size, cpuset);
				}
				CPU_FREE(cpuset);
			} else {
				cpu_set_t cpuset;
				if (sched_getaffinity(0, cpu_set_t.sizeof, &cpuset) == 0) {
					count = CPU_COUNT(&cpuset);
				}
			}

			if (count > 0)
				return cast(uint)count;
		}

		return cast(uint)sysconf(_SC_NPROCESSORS_ONLN);
	} else version (Darwin) {
		import core.sys.darwin.sys.sysctl : sysctlbyname;

		uint result;
		size_t len = result.sizeof;
		sysctlbyname("hw.physicalcpu", &result, &len, null, 0);
		return result;
	} else version (DragonFlyBSD) {
		import core.sys.dragonflybsd.sys.sysctl : sysctlbyname;

		uint result;
		size_t len = result.sizeof;
		sysctlbyname("hw.ncpu", &result, &len, null, 0);
		return result;
	} else version (FreeBSD) {
		import core.sys.freebsd.sys.sysctl : sysctlbyname;

		uint result;
		size_t len = result.sizeof;
		sysctlbyname("hw.ncpu", &result, &len, null, 0);
		return result;
	} else version (NetBSD) {
		import core.sys.netbsd.sys.sysctl : sysctlbyname;

		uint result;
		size_t len = result.sizeof;
		sysctlbyname("hw.ncpu", &result, &len, null, 0);
		return result;
	} else version (Solaris) {
		import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

		return cast(uint)sysconf(_SC_NPROCESSORS_ONLN);
	} else version (OpenBSD) {
		import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

		return cast(uint)sysconf(_SC_NPROCESSORS_ONLN);
	} else version (Hurd) {
		import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

		return cast(uint)sysconf(_SC_NPROCESSORS_ONLN);
	} else
		static assert(0, "Don't know how to get N CPUs on this OS.");
}

struct SocketData {
	int offset;
}

struct HTTPContext {
	/* The shared response */
	const(char)[] response;
}

alias C = Context!(HTTPContext, SocketData);
alias Socket = C.Socket;

void main() {
	enum port = 8090;
	enum writeData = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n" ~
		"Content-Type: text/plain\r\n\r\nHello, World!";
	Thread[512] threads = void;
	foreach (ref t; threads[0 .. totalCPUs]) {
		t = new Thread({
			auto loop = EventLoop!()(&(EventLoop!()).noop);
			auto ctx = C(loop);
			ctx.data = HTTPContext(writeData);
			ctx.onOpen = &onOpen;
			ctx.onData = &onData;
			ctx.onWritable = &onWritable;
			ctx.onClose = &onClose;
			ctx.onEnd = &onEnd;
			ctx.onTimeout = &onTimeout;

			auto server = ctx.listen("127.0.0.1", port);
			if (!server) {
				printf("Failed to listen on port %d\n", port);
				return;
			}

			printf("The server is listening on %d\n", port);
			loop.run();
		}).start();
		t.join();
	}
}

extern (C):

auto onOpen(Socket s, int isClient, char* ip, int ipLength) {
	s.data.offset = 0;
	s.timeout = 30;
	return s;
}

auto onData(Socket s, void* data, int length) {
	//debug writeln("Received data: ", cast(char*)data[0..length]);
	s.data.offset = s.write(s.context.data.response);
	s.timeout = 30;
	return s;
}

auto onWritable(Socket s) {
	s.data.offset += s.write(s.context.data.response[s.data.offset .. $]);
	return s;
}

auto onClose(Socket s, int code, void* reason) {
	debug puts("The connection is closed!");
	return s;
}

auto onTimeout(Socket s) {
	debug puts("The connection is timed out!");
	return s.close();
}

auto onEnd(Socket s) {
	s.shutdown();
	return s.close();
}
