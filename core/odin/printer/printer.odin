package odin_printer

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:runtime"
import "core:fmt"
import "core:unicode/utf8"
import "core:mem"

Type_Enum :: enum {Line_Comment, Value_Decl, Switch_Stmt, Struct, Assign, Call, Enum, If, For}

Line_Type :: bit_set[Type_Enum];

Line :: struct {
	format_tokens: [dynamic]Format_Token,
	finalized:     bool,
	used:          bool,
	depth:         int,
	types:         Line_Type, //for performance, so you don't have to verify what types are in it by going through the tokens - might give problems when adding linebreaking
}

Format_Token :: struct {
	kind:            tokenizer.Token_Kind,
	text:            string,
	type:            Type_Enum,
	spaces_before:   int,
	parameter_count: int,
}

Printer :: struct {
	string_builder:       strings.Builder,
	config:               Config,
	depth:                int, //the identation depth
	comments:             [dynamic]^ast.Comment_Group,
	latest_comment_index: int,
	allocator:            mem.Allocator,
	file:                 ^ast.File,
	source_position:      tokenizer.Pos,
	last_source_position: tokenizer.Pos,
	lines:                [dynamic]Line, //need to look into a better data structure, one that can handle inserting lines rather than appending
	skip_semicolon:       bool,
	current_line:         ^Line,
	current_line_index:   int,
	last_line_index:      int,
	last_token:           ^Format_Token,
	merge_next_token:     bool,
	space_next_token:     bool,
	debug:                bool,
}

Config :: struct {
	spaces:               int,  //Spaces per indentation
	newline_limit:        int,  //The limit of newlines between statements and declarations.
	tabs:                 bool, //Enable or disable tabs
	convert_do:           bool, //Convert all do statements to brace blocks
	semicolons:           bool, //Enable semicolons
	split_multiple_stmts: bool,
	align_switch:         bool,
	brace_style:          Brace_Style,
	align_assignments:    bool,
	align_structs:        bool,
	align_style:          Alignment_Style,
	indent_cases:         bool,
	newline_style:        Newline_Style,
}

Brace_Style :: enum {
	_1TBS,
	Allman,
	Stroustrup,
	K_And_R,
}

Block_Type :: enum {
	None,
	If_Stmt,
	Proc,
	Generic,
	Comp_Lit,
	Switch_Stmt,
}

Alignment_Style :: enum {
	Align_On_Colon_And_Equals,
	Align_On_Type_And_Equals,
}

Newline_Style :: enum {
	CRLF,
	LF,
}

default_style := Config {
	spaces = 4,
	newline_limit = 2,
	convert_do = false,
	semicolons = true,
	tabs = true,
	brace_style = ._1TBS,
	split_multiple_stmts = true,
	align_assignments = true,
	align_style = .Align_On_Type_And_Equals,
	indent_cases = false,
	align_switch = true,
	align_structs = true,
	newline_style = .CRLF,
};

make_printer :: proc(config: Config, allocator := context.allocator) -> Printer {
	return {
		config = config,
		allocator = allocator,
		debug = false,
	};
}

print :: proc(p: ^Printer, file: ^ast.File) -> string {

	p.comments = file.comments;

	if len(file.decls) > 0 {
		p.lines = make([dynamic]Line, 0, (file.decls[len(file.decls) - 1].end.line - file.decls[0].pos.line) * 2, context.temp_allocator);
	}

	set_line(p, 0);

	push_generic_token(p, .Package, 0);
	push_ident_token(p, file.pkg_name, 1);

	for decl in file.decls {
		visit_decl(p, cast(^ast.Decl)decl);
	}

	if len(p.comments) > 0 {
		infinite := p.comments[len(p.comments) - 1].end;
		infinite.offset = 9999999;
		push_comments(p, infinite);
	}

	fix_lines(p);

	builder := strings.make_builder(0, mem.megabytes(5), p.allocator);

	last_line := 0;

	newline: string;

	if p.config.newline_style == .LF {
		newline = "\n";
	} else {
		newline = "\r\n";
	}

	for line, line_index in p.lines {
		diff_line := line_index - last_line;

		for i := 0; i < diff_line; i += 1 {
			strings.write_string(&builder, newline);
		}

		if p.config.tabs {
			for i := 0; i < line.depth; i += 1 {
				strings.write_byte(&builder, '\t');
			}
		} else {
			for i := 0; i < line.depth * p.config.spaces; i += 1 {
				strings.write_byte(&builder, ' ');
			}
		}

		if p.debug {
			strings.write_string(&builder, fmt.tprintf("line %v: ", line_index));
		}

		for format_token in line.format_tokens {

			for i := 0; i < format_token.spaces_before; i += 1 {
				strings.write_byte(&builder, ' ');
			}

			strings.write_string(&builder, format_token.text);
		}

		last_line = line_index;
	}

	return strings.to_string(builder);
}

fix_lines :: proc(p: ^Printer) {
	align_var_decls_and_assignments(p);
	format_generic(p);
	align_comments(p); //align them last since they rely on the other alignments
}

format_value_decl :: proc(p: ^Printer, index: int) {

	eq_found := false;
	eq_token: Format_Token;
	eq_line: int;
	largest := 0;

	found_eq: for line, line_index in p.lines[index:] {
		for format_token in line.format_tokens {

			largest += len(format_token.text) + format_token.spaces_before;

			if format_token.kind == .Eq {
				eq_token = format_token;
				eq_line = line_index + index;
				eq_found = true;
				break found_eq;
			}
		}
	}

	if !eq_found {
		return;
	}

	align_next := false;

	//check to see if there is a binary operator in the last token(this is guaranteed by the ast visit), otherwise it's not multilined
	for line, line_index in p.lines[eq_line:] {

		if len(line.format_tokens) == 0 {
			break;
		}

		if align_next {
			line.format_tokens[0].spaces_before = largest + 1;
			align_next = false;
		}

		kind := find_last_token(line.format_tokens).kind;

		if tokenizer.Token_Kind.B_Operator_Begin < kind && kind <= tokenizer.Token_Kind.Cmp_Or {
			align_next = true;
		}

		if !align_next {
			break;
		}
	}
}

find_last_token :: proc(format_tokens: [dynamic]Format_Token) -> Format_Token {

	for i := len(format_tokens) - 1; i >= 0; i -= 1 {

		if format_tokens[i].kind != .Comment {
			return format_tokens[i];
		}
	}

	panic("not possible");
}

format_assignment :: proc(p: ^Printer, index: int) {
}

format_call :: proc(p: ^Printer, line_index: int, format_index: int) {

	paren_found := false;
	paren_token: Format_Token;
	paren_line: int;
	paren_token_index: int;
	largest := 0;

	found_paren: for line, i in p.lines[line_index:] {
		for format_token, j in line.format_tokens {

			largest += len(format_token.text) + format_token.spaces_before;

			if i == 0 && j < format_index {
				continue;
			}

			if format_token.kind == .Open_Paren && format_token.type == .Call {
				paren_token = format_token;
				paren_line = line_index + i;
				paren_found = true;
				paren_token_index = j;
				break found_paren;
			}
		}
	}

	if !paren_found {
		panic("Should not be possible");
	}

	paren_count := 1;
	done := false;

	for line, line_index in p.lines[paren_line:] {

		if len(line.format_tokens) == 0 {
			continue;
		}

		for format_token, i in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			if line_index == 0 && i <= paren_token_index {
				continue;
			}

			if format_token.kind == .Open_Paren {
				paren_count += 1;
			} else if format_token.kind == .Close_Paren {
				paren_count -= 1;
			}

			if paren_count == 0 {
				done = true;
			}
		}

		if line_index != 0 {
			line.format_tokens[0].spaces_before = largest;
		}

		if done {
			return;
		}
	}
}

format_keyword_to_brace :: proc(p: ^Printer, line_index: int, format_index: int, keyword: tokenizer.Token_Kind) {

	keyword_found := false;
	keyword_token: Format_Token;
	keyword_line: int;
	largest := 0;

	brace_count := 0;
	done := false;

	found_keyword: for line, i in p.lines[line_index:] {
		for format_token in line.format_tokens {

			largest += len(format_token.text) + format_token.spaces_before;

			if format_token.kind == keyword {
				keyword_token = format_token;
				keyword_line = line_index + i;
				keyword_found = true;
				break found_keyword;
			}
		}
	}

	if !keyword_found {
		panic("Should not be possible");
	}

	for line, line_index in p.lines[keyword_line:] {

		if len(line.format_tokens) == 0 {
			continue;
		}

		for format_token, i in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			if line_index == 0 && i <= format_index {
				continue;
			}

			if format_token.kind == .Open_Brace {
				brace_count += 1;
			} else if format_token.kind == .Close_Brace {
				brace_count -= 1;
			}

			if brace_count == 1 {
				done = true;
			}
		}

		if line_index != 0 {
			line.format_tokens[0].spaces_before = largest + 1;
		}

		if done {
			return;
		}
	}
}

format_generic :: proc(p: ^Printer) {

	for line, line_index in p.lines {

		if len(line.format_tokens) <= 0 {
			continue;
		}

		for format_token, token_index in line.format_tokens {

			if format_token.kind == .For || format_token.kind == .If ||
			   format_token.kind == .When || format_token.kind == .Switch {
				format_keyword_to_brace(p, line_index, token_index, format_token.kind);
			} else if format_token.type == .Call {
				format_call(p, line_index, token_index);
			}
		}

		if .Switch_Stmt in line.types && p.config.align_switch {
			align_switch_stmt(p, line_index);
		}

		if .Struct in line.types && p.config.align_structs {
			align_struct(p, line_index);
		}

		if .Value_Decl in line.types {
			format_value_decl(p, line_index);
		}

		if .Assign in line.types {
			format_assignment(p, line_index);
		}
	}
}

align_var_decls_and_assignments :: proc(p: ^Printer) {
}

align_switch_stmt :: proc(p: ^Printer, index: int) {

	switch_found := false;
	brace_token: Format_Token;
	brace_line: int;

	found_switch_brace: for line, line_index in p.lines[index:] {

		for format_token in line.format_tokens {

			if format_token.kind == .Open_Brace && switch_found {
				brace_token = format_token;
				brace_line = line_index + index;
				break found_switch_brace;
			} else if format_token.kind == .Open_Brace {
				break;
			} else if format_token.kind == .Switch {
				switch_found = true;
			}
		}
	}

	if !switch_found {
		return;
	}

	largest := 0;
	case_count := 0;

	//find all the switch cases that are one lined
	for line, line_index in p.lines[brace_line + 1:] {

		case_found := false;
		colon_found := false;
		length := 0;

		for format_token in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			//this will only happen if the case is one lined
			if case_found && colon_found {
				largest = max(length, largest);
				break;
			}

			if format_token.kind == .Case {
				case_found = true;
				case_count += 1;
			} else if format_token.kind == .Colon {
				colon_found = true;
			}

			length += len(format_token.text) + format_token.spaces_before;
		}

		if case_count >= brace_token.parameter_count {
			break;
		}
	}

	case_count = 0;

	for line, line_index in p.lines[brace_line + 1:] {

		case_found := false;
		colon_found := false;
		length := 0;

		for format_token, i in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			//this will only happen if the case is one lined
			if case_found && colon_found {
				line.format_tokens[i].spaces_before = (largest - length);
				break;
			}

			if format_token.kind == .Case {
				case_found = true;
				case_count += 1;
			} else if format_token.kind == .Colon {
				colon_found = true;
			}

			length += len(format_token.text) + format_token.spaces_before;
		}

		if case_count >= brace_token.parameter_count {
			break;
		}
	}
}

align_struct :: proc(p: ^Printer, index: int) {

	struct_found := false;
	brace_token: Format_Token;
	brace_line: int;

	found_struct_brace: for line, line_index in p.lines[index:] {

		for format_token in line.format_tokens {

			if format_token.kind == .Open_Brace && struct_found {
				brace_token = format_token;
				brace_line = line_index + index;
				break found_struct_brace;
			} else if format_token.kind == .Open_Brace {
				break;
			} else if format_token.kind == .Struct {
				struct_found = true;
			}
		}
	}

	if !struct_found {
		return;
	}

	largest := 0;
	colon_count := 0;

	for line, line_index in p.lines[brace_line + 1:] {

		length := 0;

		for format_token in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			if format_token.kind == .Colon {
				colon_count += 1;
				largest = max(length, largest);
				break;
			}

			length += len(format_token.text) + format_token.spaces_before;
		}

		if colon_count >= brace_token.parameter_count {
			break;
		}
	}

	colon_count = 0;

	for line, line_index in p.lines[brace_line + 1:] {

		length := 0;

		for format_token, i in line.format_tokens {

			if format_token.kind == .Comment {
				continue;
			}

			if format_token.kind == .Colon {
				colon_count += 1;
				line.format_tokens[i + 1].spaces_before = largest - length + 1;
				break;
			}

			length += len(format_token.text) + format_token.spaces_before;
		}

		if colon_count >= brace_token.parameter_count {
			break;
		}
	}
}

align_comments :: proc(p: ^Printer) {

	Comment_Align_Info :: struct {
		length: int,
		begin:  int,
		end:    int,
		depth:  int,
	};

	comment_infos := make([dynamic]Comment_Align_Info, 0, context.temp_allocator);

	current_info: Comment_Align_Info;

	for line, line_index in p.lines {

		if len(line.format_tokens) <= 0 {
			continue;
		}

		if .Line_Comment in line.types {

			if current_info.end + 1 != line_index || current_info.depth != line.depth ||
			   (current_info.begin == current_info.end && current_info.length == 0) {

				if (current_info.begin != 0 && current_info.end != 0) || current_info.length > 0 {
					append(&comment_infos, current_info);
				}

				current_info.begin = line_index;
				current_info.end = line_index;
				current_info.depth = line.depth;
				current_info.length = 0;
			}

			length := 0;

			for format_token, i in line.format_tokens {

				if format_token.kind == .Comment {
					current_info.length = max(current_info.length, length);
					current_info.end = line_index;
				}

				length += format_token.spaces_before + len(format_token.text);
			}
		}
	}

	if (current_info.begin != 0 && current_info.end != 0) || current_info.length > 0 {
		append(&comment_infos, current_info);
	}

	for info in comment_infos {

		if info.begin == info.end || info.length == 0 {
			continue;
		}

		for i := info.begin; i <= info.end; i += 1 {

			l := p.lines[i];

			length := 0;

			for format_token, i in l.format_tokens {

				if format_token.kind == .Comment {
					if len(l.format_tokens) == 1 {
						l.format_tokens[i].spaces_before = info.length + 1;
					} else {
						l.format_tokens[i].spaces_before = info.length - length + 1;
					}
				}

				length += format_token.spaces_before + len(format_token.text);
			}
		}
	}
}