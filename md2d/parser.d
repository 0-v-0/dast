module md2d.parser;

import md2d.link,
md2d.util,
std.array,
std.range,
std.string;
import std.algorithm : canFind, countUntil, min;
import std.ascii : isAlpha, isWhite;

struct MarkdownSettings {
	/// Controls the capabilities of the parser
	MarkdownFlags flags = MarkdownFlags.githubInspired;

	/// Heading tags will start at this level
	size_t headingBaseLevel = 1;
	/+
	/// Called for every link/image URL to perform arbitrary transformations
	string delegate(string url_or_path, bool is_image) urlFilter;

	/++ An optional delegate to post-process code blocks and inline code.

		Useful to e.g. add code highlighting.
	 +/
	string delegate(string) @safe nothrow processCode = null;
+/
	bool noComment;
}

enum MarkdownFlags {
	none = 0,
	keepLineBreaks = 1 << 0,
	backtickCodeBlocks = 1 << 1,
	noInlineHtml = 1 << 2,
	//noLinks = 1<<3,
	//allowUnsafeHtml = 1<<4,
	/// If used, subheadings are underlined by stars ('*') instead of dashes ('-')
	alternateSubheaders = 1 << 5,
	/// If used, '_' may not be used for emphasis ('*' may still be used)
	disableUnderscoreEmphasis = 1 << 6,
	supportTables = 1 << 7,
	vanillaMarkdown = none,
	forumDefault = keepLineBreaks | backtickCodeBlocks | noInlineHtml,
	githubInspired = backtickCodeBlocks | supportTables,
}

enum IndentType {
	White,
	Quote
}

enum LineType {
	Undefined,
	Blank,
	Plain,
	Hline,
	AtxHeader,
	SetextHeader,
	UList,
	OList,
	HtmlBlock,
	CodeBlockDelimiter,
	Table,
}

struct Line {
	LineType type;
	IndentType[] indent;
	string text;
	string unindented;

	string unindent(size_t n) pure @safe {
		assert(n <= indent.length);
		string ln = text;
		foreach (i; 0 .. n) {
			final switch (indent[i]) {
			case IndentType.White:
				ln = ln[ln[0] == ' ' ? 4: 1 .. $];
				break;
			case IndentType.Quote:
				ln = stripLeft(ln)[1 .. $];
				break;
			}
		}
		return ln;
	}
}

struct Section {
	size_t headingLevel;
	string caption;
	string anchor;
	Section[] subSections;
}

/++
	Returns the hierarchy of sections
+/
Section[] getMarkdownOutline(string md_source, scope MarkdownSettings settings = MarkdownSettings()) {
	auto all_lines = splitLines(md_source);
	auto lines = parseLines(all_lines, settings);
	Block root_block;
	parseBlocks(root_block, lines, null, settings);
	Section root;

	foreach (ref sb; root_block.blocks) {
		if (sb.type == BlockType.Header) {
			auto s = &root;
			for (;;) {
				if (s.subSections.length == 0)
					break;
				if (s.subSections[$ - 1].headingLevel >= sb.headerLevel)
					break;
				s = &s.subSections[$ - 1];
			}
			s.subSections ~= Section(sb.headerLevel, sb.text[0], sb.text[0].asSlug.to!string);
		}
	}

	return root.subSections;
}

@safe:

Line[] parseLines(ref string[] lines, scope MarkdownSettings settings) pure {
	Line[] ret;
	const subHeaderChar = settings.flags * MarkdownFlags.alternateSubheaders ? '*' : '-';
	while (!lines.empty) {
		auto ln = lines.front;
		lines.popFront();

		Line lninfo;
		lninfo.text = ln;

		while (ln.length) {
			if (ln[0] == '\t') {
				lninfo.indent ~= IndentType.White;
				ln.popFront();
			} else if (ln.startsWith("    ")) {
				lninfo.indent ~= IndentType.White;
				ln.popFrontN(4);
			} else {
				ln = ln.stripLeft();
				if (ln.startsWith('>')) {
					lninfo.indent ~= IndentType.Quote;
					ln.popFront();
				} else
					break;
			}
		}
		lninfo.unindented = ln;

		if ((settings.flags & MarkdownFlags.backtickCodeBlocks) && isCodeBlockDelimiter(ln))
			lninfo.type = LineType.CodeBlockDelimiter;
		else if (isAtxHeaderLine(ln))
			lninfo.type = LineType.AtxHeader;
		else if (isSetextHeaderLine(ln, subHeaderChar))
			lninfo.type = LineType.SetextHeader;
		else if ((settings.flags & MarkdownFlags.supportTables) && isTableRowLine!false(ln))
			lninfo.type = LineType.Table;
		else if (isHlineLine(ln))
			lninfo.type = LineType.Hline;
		else if (isOListLine(ln))
			lninfo.type = LineType.OList;
		else if (isUListLine(ln))
			lninfo.type = LineType.UList;
		else if (isLineBlank(ln))
			lninfo.type = LineType.Blank;
		else if (!(settings.flags & MarkdownFlags.noInlineHtml) && isHtmlBlockLine(ln))
			lninfo.type = LineType.HtmlBlock;
		else
			lninfo.type = LineType.Plain;

		ret ~= lninfo;
	}
	return ret;
}

enum BlockType {
	Plain,
	Text,
	Paragraph,
	Header,
	OList,
	UList,
	ListItem,
	Code,
	Quote,
	Table,
	TableRow,
	TableHeader,
	TableData,
}

struct Block {
	BlockType type;
	string[] text;
	Block[] blocks;
	size_t headerLevel;

	// A human-readable toString for debugging
	string toString() {
		auto app = appender!string;
		toStringNested(app);
		return app[];
	}

	// toString implementation; capable of indenting nested blocks
	void toStringNested(R)(ref R appender, uint depth = 0) {
		import std.format;

		auto indent = "  ".replicate(depth);
		appender.put(indent);
		appender.put("%s\n".format(type));
		appender.put(indent);
		appender.put("%s\n".format(text));
		foreach (block; blocks)
			block.toStringNested(appender, depth + 1);
		appender.put(indent);
		appender.put("%s\n".format(headerLevel));
	}
}

pure:

void parseBlocks(ref Block root, ref Line[] lines, IndentType[] base_indent, scope MarkdownSettings settings) {
	if (base_indent.length == 0)
		root.type = BlockType.Text;
	else if (base_indent[$ - 1] == IndentType.Quote)
		root.type = BlockType.Quote;

	while (!lines.empty) {
		auto ln = lines.front;

		if (ln.type == LineType.Blank) {
			lines.popFront();
			continue;
		}

		if (ln.indent != base_indent) {
			if (ln.indent.length < base_indent.length || ln.indent[0 .. base_indent.length] != base_indent)
				return;

			auto cindent = base_indent ~ IndentType.White;
			if (ln.indent == cindent) {
				Block cblock;
				cblock.type = BlockType.Code;
				while (!lines.empty && lines.front.indent.length >= cindent.length
					&& lines.front.indent[0 .. cindent.length] == cindent) {
					cblock.text ~= lines.front.unindent(cindent.length);
					lines.popFront();
				}
				root.blocks ~= cblock;
			} else {
				Block subblock;
				parseBlocks(subblock, lines, ln.indent[0 .. base_indent.length + 1], settings);
				root.blocks ~= subblock;
			}
		} else {
			Block b;
			void processPlain() {
				b.type = BlockType.Paragraph;
				b.text = skipText(lines, base_indent);
			}

			final switch (ln.type) {
			case LineType.Undefined:
			case LineType.Blank:
				assert(0);
			case LineType.Plain:
				if (lines.length >= 2 && lines[1].type == LineType.SetextHeader) {
					auto setln = lines[1].unindented;
					b.type = BlockType.Header;
					b.text = [ln.unindented];
					b.headerLevel = setln.strip()[0] == '=' ? 1 : 2;
					lines.popFrontN(2);
				} else {
					processPlain();
				}
				break;
			case LineType.Hline:
				b.type = BlockType.Plain;
				b.text = ["<hr>"];
				lines.popFront();
				break;
			case LineType.AtxHeader:
				b.type = BlockType.Header;
				string hl = ln.unindented;
				b.headerLevel = 0;
				while (hl.length && hl[0] == '#') {
					b.headerLevel++;
					hl = hl[1 .. $];
				}
				while (hl.length && (hl[$ - 1] == '#' || hl[$ - 1] == ' '))
					hl = hl[0 .. $ - 1];
				b.text = [hl];
				lines.popFront();
				break;
			case LineType.SetextHeader:
				lines.popFront();
				break;
			case LineType.UList:
			case LineType.OList:
				b.type = ln.type == LineType.UList ? BlockType.UList : BlockType.OList;
				auto itemindent = base_indent ~ IndentType.White;
				bool firstItem = true, paraMode = false;
				while (!lines.empty && lines.front.type == ln.type && lines.front.indent == base_indent) {
					Block itm;
					itm.text = skipText(lines, itemindent);
					itm.text[0] = removeListPrefix(itm.text[0], ln.type);

					// emit <p></p> if there are blank lines between the items
					if (firstItem && !lines.empty && lines.front.type == LineType.Blank)
						paraMode = true;
					firstItem = false;
					if (paraMode) {
						Block para;
						para.type = BlockType.Paragraph;
						para.text = itm.text;
						itm.blocks ~= para;
						itm.text = null;
					}

					parseBlocks(itm, lines, itemindent, settings);
					itm.type = BlockType.ListItem;
					b.blocks ~= itm;
				}
				break;
			case LineType.HtmlBlock:
				int nestlevel = 0;
				auto starttag = parseHtmlBlockLine(ln.unindented);
				if (!starttag.isHtmlBlock || !starttag.open)
					break;

				b.type = BlockType.Plain;
				while (!lines.empty) {
					if (lines.front.indent.length < base_indent.length)
						break;
					if (lines.front.indent[0 .. base_indent.length] != base_indent)
						break;

					auto str = lines.front.unindent(base_indent.length);
					auto taginfo = parseHtmlBlockLine(str);
					b.text ~= lines.front.unindent(base_indent.length);
					lines.popFront();
					if (taginfo.isHtmlBlock && taginfo.tagName == starttag.tagName)
						nestlevel += taginfo.open ? 1 : -1;
					if (nestlevel <= 0)
						break;
				}
				break;
			case LineType.CodeBlockDelimiter:
				lines.popFront(); // TODO: get language from line
				b.type = BlockType.Code;
				while (!lines.empty) {
					if (lines.front.indent.length < base_indent.length)
						break;
					if (lines.front.indent[0 .. base_indent.length] != base_indent)
						break;
					if (lines.front.type == LineType.CodeBlockDelimiter) {
						lines.popFront();
						break;
					}
					b.text ~= lines.front.unindent(base_indent.length);
					lines.popFront();
				}
				break;
			case LineType.Table:
				lines.popFront();
				// Can this be a valid table (is there a next line that could be a header separator)?
				if (lines.empty) {
					processPlain();
					break;
				}
				Line lnNext = lines.front;
				immutable bool isTableHeader =
					lnNext.type == LineType.Table
					&& lnNext.text.indexOf(" -") >= 0
					&& lnNext.text.indexOf("- ") >= 0
					&& lnNext.text.allOf("-:| ");
				if (!isTableHeader) {
					// Not a valid table header, so let's assume it's plain markdown
					processPlain();
					break;
				}
				b.type = BlockType.Table;
				// Parse header
				b.blocks ~= ln.splitTableRow!(BlockType.TableHeader)();
				// Parse table rows
				lines.popFront();
				while (!lines.empty) {
					ln = lines.front;
					if (ln.type != LineType.Table)
						break; // not a table row, so let's assume it's the end of the table
					b.blocks ~= ln.splitTableRow();
					lines.popFront();
				}
				break;
			}
			root.blocks ~= b;
		}
	}
}

bool matchesIndent(IndentType[] indent, IndentType[] base_indent) {
	// Any *plain* line with a higher indent should still be a part of
	// a paragraph read by skipText(). Returning false here resulted in
	// text such as:
	// ---
	// First line
	//         Second line
	// ---
	// being interpreted as a paragraph followed by a code block, even though
	// other Markdown processors would interpret it as a single paragraph.

	// if(indent.length > base_indent.length) return false;
	if (indent.length > base_indent.length)
		return true;
	if (indent != base_indent[0 .. indent.length])
		return false;
	sizediff_t qidx = -1;
	foreach_reverse (i, tp; base_indent)
		if (tp == IndentType.Quote) {
			qidx = i;
			break;
		}
	if (qidx >= 0) {
		qidx = base_indent.length - 1 - qidx;
		if (indent.length <= qidx)
			return false;
	}
	return true;
}

string[] skipText(ref Line[] lines, IndentType[] indent) {
	string[] ret;

	for (;;) {
		ret ~= lines.front.unindent(min(indent.length, lines.front.indent.length));
		lines.popFront();

		if (lines.empty || !matchesIndent(lines.front.indent, indent) || lines.front.type != LineType
			.Plain)
			return ret;
	}
}

Block splitTableRow(BlockType dataType = BlockType.TableData)(Line line) {
	static assert(dataType == BlockType.TableHeader || dataType == BlockType.TableData);

	string ln = line.text.strip();
	immutable b = ln[0 .. 2] == "| " ? 2 : 0;
	immutable e = ln[$ - 2 .. $] == " |" ? ln.length - 2 : ln.length;
	Block ret;
	ret.type = BlockType.TableRow;
	foreach (txt; ln[b .. e].split(" | ")) {
		Block d;
		d.text = [txt.strip(" ")];
		d.type = dataType;
		ret.blocks ~= d;
	}
	return ret;
}

string removeListPrefix(string str, LineType tp) {
	switch (tp) {
	default:
		assert(0);
	case LineType.OList: // skip bullets and output using normal escaping
		auto idx = str.indexOf('.');
		assert(idx > 0);
		return str[idx + 1 .. $].stripLeft();
	case LineType.UList:
		return stripLeft(str.stripLeft()[1 .. $]);
	}
}

immutable BlockTags = ["div", "ol", "p", "pre", "section", "table", "ul"];

struct HtmlBlockInfo {
	bool isHtmlBlock;
	string tagName;
	bool open;
}

auto parseHtmlBlockLine(string ln) {
	auto ret = HtmlBlockInfo(false, "", true);

	ln = ln.strip;
	if (ln.length < 3)
		return ret;
	if (ln[0] != '<')
		return ret;
	if (ln[1] == '/') {
		ret.open = false;
		ln = ln[1 .. $];
	}
	if (!isAlpha(ln[1]))
		return ret;
	ln = ln[1 .. $];
	size_t idx = 0;
	while (idx < ln.length && ln[idx] != ' ' && ln[idx] != '>')
		idx++;
	ret.tagName = ln[0 .. idx];
	ln = ln[idx .. $];

	auto eidx = ln.indexOf('>');
	if (eidx < 0)
		return ret;
	if (eidx != ln.length - 1)
		return ret;

	if (!BlockTags.canFind(ret.tagName))
		return ret;

	ret.isHtmlBlock = true;
	return ret;
}

bool isHtmlBlockLine(string ln) {
	auto bi = parseHtmlBlockLine(ln);
	return bi.isHtmlBlock && bi.open;
}

bool isHtmlBlockCloseLine(string ln) {
	auto bi = parseHtmlBlockLine(ln);
	return bi.isHtmlBlock && !bi.open;
}

string getHtmlTagName(string ln) => parseHtmlBlockLine(ln).tagName;

int parseEmphasis(ref string str, ref string text) {
	if (str.length < 3)
		return false;

	string pstr = str;
	string ctag;
	if (pstr.startsWith("***"))
		ctag = "***";
	else if (pstr.startsWith("**"))
		ctag = "**";
	else if (pstr.startsWith('*'))
		ctag = "*";
	else if (pstr.startsWith("___"))
		ctag = "___";
	else if (pstr.startsWith("__"))
		ctag = "__";
	else if (pstr.startsWith('_'))
		ctag = "_";
	else
		return false;

	pstr = pstr[ctag.length .. $];

	auto cidx = pstr.indexOf(ctag);
	if (cidx < 1)
		return false;

	text = pstr[0 .. cidx];

	str = pstr[cidx + ctag.length .. $];
	return cast(int)ctag.length;
}

bool parseInlineCode(ref string str, ref string code) {
	if (str.length < 3)
		return false;

	string pstr = str;
	string ctag;
	if (pstr.startsWith("``"))
		ctag = "``";
	else if (pstr.startsWith('`'))
		ctag = "`";
	else
		return false;
	pstr = pstr[ctag.length .. $];

	auto cidx = pstr.indexOf(ctag);
	if (cidx < 1)
		return false;

	code = pstr[0 .. cidx];
	str = pstr[cidx + ctag.length .. $];
	return true;
}
