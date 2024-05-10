/++
 * md2d
 * modified from https://github.com/dlang-community/dmarkdown/blob/master/source/dmarkdown/markdown.d
 +/
module md2d;

import std.string;
import std.algorithm : canFind;
import md2d.parser : Block, MarkdownSettings;

unittest {
	mixin(md2d(`
### Status 枚举
状态
| 序号 | 字段名 | 名称 | 说明 |
| --- | --- | --- | --- |
| 2 | active | 正常 |  |`));
	static assert(Status.active == 2);
}

private void addField(S)(ref S r, S name, S type = null,
	S val = null, S comment = null) {
	r ~= '\t';
	if (comment.length) {
		bool multiline = comment.canFind('\n');
		r ~= multiline ? "/++\n\t\t" : "/// ";
		r ~= comment;
		r ~= multiline ? "\n\t  +/\n\t" : "\n\t";
	}
	if (type.length) {
		r ~= type;
		r ~= ' ';
	}
	r ~= name.replace(' ', '_');
	if (val.length) {
		r ~= " = ";
		r ~= val;
	}
	r ~= type ? ";\n" : ",\n";
}

void parseMD(string src, ref Block block, MarkdownSettings settings = MarkdownSettings()) {
	import md2d.parser;

	auto allLines = src.splitLines;
	auto lines = parseLines(allLines, settings);
	parseBlocks(block, lines, null, settings);
}

string md2d(string src, MarkdownSettings settings = MarkdownSettings()) {
	import md2d.parser : BT = BlockType;

	Block root;
	parseMD(src, root, settings);
	string str, header;
	foreach (b; root.blocks) {
		if (b.type == BT.Header && b.headerLevel > 1) {
			string cls, t = b.text[0].strip;
			if (t[0] == '`')
				t = t.split('`')[1];
			else if (t.endsWith("struct")) {
				cls = "struct";
				t = t[0 .. $ - "struct".length];
			} else if (t.endsWith("结构体")) {
				cls = "struct";
				t = t[0 .. $ - "结构体".length];
			} else if (t.endsWith("union")) {
				cls = "union";
				t = t[0 .. $ - "union".length];
			} else if (t.endsWith("联合体")) {
				cls = "union";
				t = t[0 .. $ - "联合体".length];
			} else if (t.endsWith("class")) {
				cls = "class";
				t = t[0 .. $ - "class".length];
			} else if (t.endsWith("类")) {
				cls = "class";
				t = t[0 .. $ - "类".length];
			} else if (t.endsWith("enum")) {
				cls = "enum";
				t = t[0 .. $ - "enum".length];
			} else if (t.endsWith("表")) {
				cls = "enum";
				t = t[0 .. $ - "表".length];
			} else if (t.endsWith("枚举")) {
				cls = "enum";
				t = t[0 .. $ - "枚举".length];
			} else
				continue;
			t = t.stripRight;
			if (!t.canFind(' ')) {
				if (header)
					str ~= "}\n\n";
				if (cls) {
					char c = t[0];
					if (c >= 'A' && c <= 'Z')
						header = "/// " ~ t ~ "\n" ~ cls ~ " " ~ t ~ "\n{\n";
					else if (cls.length == 4)
						header = "/// " ~ t ~ "\n" ~ cls ~ "\n{\n";
				} else
					header = t ~ " {\n";
			}
		} else if (header) {
			if (b.type == BT.Table) {
				str ~= header;
				int nRow = -1,
				tRow = -1,
				vRow = -1,
				cRow1 = -1,
				cRow2 = -1;
				foreach (r; b.blocks)
					if (r.type == BT.TableRow) {
						string name, type, val, comment;
						for (int i; i < r.blocks.length; i++) {
							auto c = r.blocks[i];
							if (c.type == BT.TableHeader) {
								string t = c.text[0];
								if (t.startsWith("Field") || t.startsWith("字段"))
									nRow = i;
								else if (t == "Type" || t.endsWith("类型"))
									tRow = i;
								else if (t == "Value" || t.endsWith("值") || t == "Index" || t == "序号")
									vRow = i;
								else if (t == "Name" || t.endsWith("名称") || t.startsWith(
										"中文"))
									cRow1 = i;
								else if (t == "Description" || t.endsWith("说明"))
									cRow2 = i;
							} else if (c.type == BT.TableData) {
								if (i == nRow)
									name = c.text[0];
								else if (i == tRow)
									type = c.text[0];
								else if (i == vRow)
									val = c.text[0];
								else {
									if (!settings.noComment)
										if (i == cRow1)
											comment = c.text[0].strip;
								}
							}
						}
						if (name)
							str.addField(name, type, val, comment);
					}
			} else if (b.type == BT.Plain) {
				str ~= "}\n\n";
				header = null;
			}
		}
		if (b.type == BT.Code) {
			if (header) {
				str ~= header ~ '\t';
				header = " ";
			}
			str ~= b.text.join("\n\t") ~ '\n';
		}
	}
	if (header)
		str ~= '}';
	return str;
}
