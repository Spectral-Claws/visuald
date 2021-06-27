// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2010 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module visuald.stringutil;

import visuald.windows;
import visuald.comutil;

import stdext.file;

import core.stdc.stdlib;
//import std.windows.charset;
import stdext.path;
import std.path;
import std.utf;
import std.string;
import std.ascii;
import std.conv;
import std.array;
import std.algorithm;

string ellipseString(string s, int maxlen)
{
	if (s.length > maxlen - 1)
		s = s[0 .. maxlen - 4] ~ "...";
	return s;
}


void addFileMacros(string path, string base, ref string[string] replacements, string workdir = null)
{
	replacements[base ~ "PATH"] = path;
	string fullpath = makeFilenameCanonical(path, workdir);
	replacements[base ~ "FULLPATH"] = fullpath;
	replacements[base ~ "DIR"] = dirName(path);
	replacements[base ~ "FULLDIR"] = dirName(fullpath);
	string filename = baseName(path);
	string ext = extension(path);
	if(ext.startsWith("."))
		ext = ext[1..$];
	replacements[base ~ "FILENAME"] = filename;
	replacements[base ~ "EXT"] = ext;
	string name = stripExtension(filename);
	replacements[base ~ "NAME"] = name.length == 0 ? filename : name;
}

string getEnvVar(string var)
{
	wchar[256] wbuf;
	const(wchar)* wvar = toUTF16z(var);
	uint cnt = GetEnvironmentVariable(wvar, wbuf.ptr, 256);
	if(cnt < 256)
		return to_string(wbuf.ptr, cnt);
	wchar[] pbuf = new wchar[cnt+1];
	cnt = GetEnvironmentVariable(wvar, pbuf.ptr, cnt + 1);
	return to_string(pbuf.ptr, cnt);
}

string _replaceMacros(string start, dchar end, string esc)(string s, string[string] replacements)
{
	size_t[string] lastReplacePos;
	auto slen = start.length;

	for(size_t i = 0; i + slen < s.length; )
	{
		if(s[i .. i+esc.length] == esc)
			s = s[0 .. i] ~ s[i + 1 .. $];
		else if(s[i .. i+slen] == start)
		{
			auto len = indexOf(s[i+slen .. $], end);
			if(len < 0)
				break;
			string id = toUpper(s[i + slen .. i + slen + len]);
			string nid;
			if(string *ps = id in replacements)
				nid = *ps;
			else
				nid = getEnvVar(id);

			auto p = id in lastReplacePos;
			if(!p || *p <= i)
			{
				s = s[0 .. i] ~ nid ~ s[i + slen + 1 + len .. $];
				ptrdiff_t difflen = nid.length - (len + slen + 1);
				foreach(ref size_t pos; lastReplacePos)
					if(pos > i)
						pos += difflen;
				lastReplacePos[id] = i + nid.length;
				continue;
			}
		}
		i++;
	}

	return s;
}

string replaceMacros(string s, string[string] replacements)
{
	return _replaceMacros!("$(", ')', "$$")(s, replacements);
}

string replaceEnvironment(string s, string[string] replacements)
{
	return _replaceMacros!("%", '%', "%%")(s, replacements);
}

// ATTENTION: env modified
string[string] expandIniSectionEnvironment(string txt, string[string] env)
{
	string[2][] lines = parseIniSectionAssignments(txt);
	foreach(ref record; lines)
	{
		string id = toUpper(record[0]);
		string expr = record[1];
		string val = replaceEnvironment(expr, env);
		env[id] = val;
	}
	return env;
}

unittest
{
	string[string] env = [ "V1" : "x1", "V2" : "x2" ];
	string ini = `
		i1 = i%v1%
		; comment
		i2 = %i1%_i2
		; comment with =
		v2 = %v2%;i2`;
	env = expandIniSectionEnvironment(ini, env);
	//import std.stdio;
	//writeln(env);
	assert(env["I1"] == "ix1");
	assert(env["I2"] == "ix1_i2");
	assert(env["V1"] == "x1");
	assert(env["V2"] == "x2;i2");
}

S createPasteString(S)(S s)
{
	S t;
	bool wasWhite = false;
	foreach(dchar ch; s)
	{
		if(t.length > 30)
			return t ~ "...";
		bool isw = isWhite(ch);
		if(ch == '&')
			t ~= "&&";
		else if(!isw)
			t ~= ch;
		else if(!wasWhite)
			t ~= ' ';
		wasWhite = isw;
	}
	return t;
}

// special version of std.string.indexOf that considers '.', '/' and '\\' the same
//  character for case insensitive searches
ptrdiff_t indexOfPath(Char1, Char2)(const(Char1)[] s, const(Char2)[] sub,
									std.string.CaseSensitive cs = std.string.CaseSensitive.yes)
{
	const(Char1)[] balance;
	if (cs == std.string.CaseSensitive.yes)
	{
		balance = std.algorithm.find(s, sub);
	}
	else
	{
		static bool isSame(Char1, Char2)(Char1 c1, Char2 c2)
		{
			import std.uni : toLower;
			if (c1 == '.' || c1 == '/' || c1 == '\\')
				return c2 == '.' || c2 == '/' || c2 == '\\';
			return toLower(c1) == toLower(c2);
		}
		balance = std.algorithm.find!((a, b) => isSame(a, b))(s, sub);
	}
	return balance.empty ? -1 : balance.ptr - s.ptr;
}
