module dast.http;

enum Status {
	OK = "200 OK",
	NoContent = "204 No Content",
	Unauthorized = "401 Unauthorized",
	Forbidden = "403 Forbidden",
	NotFound = "404 Not Found",
	MethodNotAllowed = "405 Method Not Allowed",
	Error = "500 Internal Server Error"
}

struct Request {
	import dast.map;

	string method, path, httpVersion;
	Map headers;
	string message;

	bool tryParse(in void[] data) nothrow {
		import std.algorithm : endsWith;
		import std.ascii;

		auto msg = cast(string)data;
		if (!msg.endsWith("\r\n\r\n"))
			return false;

		size_t i, pos;

		// get method
		for (; i < msg.length; i++)
			if (msg[i] == ' ')
				break;

		method = msg[0..i];
		pos = ++i; // skip whitespace

		// get path
		for (; i < msg.length; i++)
			if (msg[i] == ' ')
				break;

		path = msg[pos..i];
		pos = ++i;

		// get version
		for (; i < msg.length; i++)
			if (msg[i] == '\r')
				break;

		i++; // skip \r
		if (msg[i] != '\n')
			return false;
		httpVersion = msg[pos..i-1];
		pos = i++;

		// get headers
		string key;
		for (; i < msg.length; i++) {
			if (msg[i] == '\r')
				break;
			pos = i;
			for (; i < msg.length; i++) {
				if (msg[i] == ':' || msg[i].isWhite)
					break;
				(cast(char[])msg)[i] = toLower(msg[i]);
			}

			key = msg[pos .. i];
			i++;
			for (; i < msg.length; i++)
				if (!msg[i].isWhite)
					break; // ignore whitespace
			pos = i;
			for (; i < msg.length; i++)
				if (msg[i] == '\r')
					break;

			i++;
			if (msg[i] != '\n')
				return false;
			headers[key] = msg[pos .. i - 1];
		}

		i++;
		if (msg[i] != '\n')
			return false;
		i++;

		message = msg[i .. $];
		return true;
	}
}
