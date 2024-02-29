module dast.async.iocp;

version (Windows)  : import dast.async.tcplistener;
package import core.sys.windows.windows,
core.sys.windows.mswsock;

package(dast.async) bool checkErro()(int ret, string prefix = null) nothrow {
	import core.sys.windows.winerror;

	const err = WSAGetLastError();
	if (ret != 0 || err == 0)
		return false;

	debug (Log)
		tracef("fd=", handle, ", dwLastError=", err);

	if (err == WSAEWOULDBLOCK || err == ERROR_IO_PENDING)
		return false;
	onError(text(prefix, " error: code=", err));
	return true;
}

enum IocpOperation {
	accept,
	connect,
	read,
	write,
	event,
	close
}

struct IocpContext {
	OVERLAPPED overlapped;
	IocpOperation operation;
}

alias LPWSAOVERLAPPED = OVERLAPPED*,
GROUP = uint;
package alias LPWSAPROTOCOL_INFO = void*;

immutable {
	LPFN_ACCEPTEX AcceptEx;
	LPFN_CONNECTEX ConnectEx;
	/*
	LPFN_DISCONNECTEX DisconnectEx;
	LPFN_GETACCEPTEXSOCKADDRS GetAcceptexSockAddrs;
	LPFN_TRANSMITFILE TransmitFile;
	LPFN_TRANSMITPACKETS TransmitPackets;
	LPFN_WSARECVMSG WSARecvMsg;
	LPFN_WSASENDMSG WSASendMsg;*/
}

shared static this() {
	auto sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	scope (exit)
		closesocket(sock);
	sock.getFuncPointer!AcceptEx(WSAID_ACCEPTEX);
	sock.getFuncPointer!ConnectEx(WSAID_CONNECTEX);
	/* sock.getFuncPointer!DisconnectEx(WSAID_DISCONNECTEX);
	sock.getFuncPointer!GetAcceptexSockAddrs(WSAID_GETACCEPTEXSOCKADDRS);
	sock.getFuncPointer!TransmitFile(WSAID_TRANSMITFILE);
	sock.getFuncPointer!TransmitPackets(WSAID_TRANSMITPACKETS);
	sock.getFuncPointer!WSARecvMsg(WSAID_WSARECVMSG); */
}

package void getFuncPointer(alias pfn)(SOCKET sock, GUID guid) {
	import std.exception;

	DWORD bytesReturned;
	if (WSAIoctl(sock, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, guid.sizeof,
			cast(void*)&pfn, pfn.sizeof, &bytesReturned, null, null) == SOCKET_ERROR)
		throw new ErrnoException("Get function failed", WSAGetLastError());
}

enum : DWORD {
	IOCPARAM_MASK = 0x7f,
	IOC_VOID = 0x20000000,
	IOC_OUT = 0x40000000,
	IOC_IN = 0x80000000,
	IOC_INOUT = IOC_IN | IOC_OUT
}

enum {
	IOC_UNIX = 0x00000000,
	IOC_WS2 = 0x08000000,
	IOC_PROTOCOL = 0x10000000,
	IOC_VENDOR = 0x18000000
}

enum _WSAIORW(int x, int y) = IOC_INOUT | x | y;

enum SIO_GET_EXTENSION_FUNCTION_POINTER = _WSAIORW!(IOC_WS2, 6);
enum WSA_FLAG_OVERLAPPED = 1;

extern (Windows) nothrow @nogc:

int WSARecv(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD, LPWSAOVERLAPPED,
	LPWSAOVERLAPPED_COMPLETION_ROUTINE);
int WSARecvDisconnect(SOCKET, LPWSABUF);
int WSARecvFrom(SOCKET, LPWSABUF, DWORD, LPDWORD, LPDWORD, SOCKADDR*, LPINT,
	LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);

int WSASend(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD, LPWSAOVERLAPPED,
	LPWSAOVERLAPPED_COMPLETION_ROUTINE);
int WSASendDisconnect(SOCKET, LPWSABUF);
int WSASendTo(SOCKET, LPWSABUF, DWORD, LPDWORD, DWORD, const(SOCKADDR)*, int,
	LPWSAOVERLAPPED, LPWSAOVERLAPPED_COMPLETION_ROUTINE);

int GetQueuedCompletionStatusEx(HANDLE, LPOVERLAPPED_ENTRY, ULONG, PULONG,
	DWORD, BOOL);

SOCKET WSASocketW(int af, int type, int protocol, LPWSAPROTOCOL_INFO lpProtocolInfo, GROUP g, DWORD dwFlags);

alias WSASocket = WSASocketW;
alias LPOVERLAPPED_ENTRY = OVERLAPPED_ENTRY*;

struct OVERLAPPED_ENTRY {
	ULONG_PTR lpCompletionKey;
	LPOVERLAPPED lpOverlapped;
	ULONG_PTR Internal;
	DWORD dwNumberOfBytesTransferred;
}
