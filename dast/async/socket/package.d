module dast.async.socket;

version (Posix) public import dast.async.socket.posix;

version (Windows) public import dast.async.socket.iocp;
