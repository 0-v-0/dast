auto cb(char* data, size_t size, size_t nmemb, void* strm) {
	auto realsz = size * nmemb;
	auto resp = cast(char[]*)strm;
	*resp ~= data[0 .. realsz];
	return realsz;
}

int main(string[] args) {
	import core.stdc.stdio,
	core.stdc.string,
	etc.c.curl,
	std.parallelism,
	std.string,
	std.stdio;
	import std.conv : to;
	import std.range : iota;

	if (args.length < 2) {
		puts("Usage: scraper [start] [end] <outfile>");
		return 1;
	}
	auto file = File(args[$ - 1], "ab");
	void append(T)(T[] buf) {
		file.rawWrite(buf);
	}

	curl_global_init(CurlGlobal.all);
	auto start = args.length > 2 ? args[1].to!uint : 0;
	auto end = args.length > 3 ? args[2].to!uint : start + 20;
	foreach (i; parallel(iota(start, end))) {
		if (i % 20 == 0)
			printf("%lld\n", i * 1L);
		auto url = "http://" ~ i.to!string(36) ~ ".com";
		auto ch = curl_easy_init();
		scope (exit)
			curl_easy_cleanup(ch);
		char[] resp;
		curl_easy_setopt(ch, CurlOption.url, url.toStringz);
		curl_easy_setopt(ch, CurlOption.connecttimeout, 8L);
		curl_easy_setopt(ch, CurlOption.writedata, &resp);
		curl_easy_setopt(ch, CurlOption.writefunction, &cb);
		auto code = curl_easy_perform(ch);
		if (code != CurlError.ok || resp.length < 18)
			continue;
		auto start = strstr(resp.toStringz, "<title>");
		if (!start)
			continue;
		start += "<title>".length;
		if (!*start)
			continue;
		auto end = strstr(start, "</title>");
		if (!end)
			continue;
		auto title = start[0 .. end - start];
		append(`<b><a href="`);
		append(url);
		append(`">`);
		append(url);
		append(`</a></b>: `);
		append(title);
		append(`<br>`);
	}
	return 0;
}
