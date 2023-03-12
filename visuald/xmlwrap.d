// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2010 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module visuald.xmlwrap;

version(D_Version2)
{
private static import stdxml = stdext.xml;

alias stdxml.Element Element;
alias stdxml.Document Document;

alias stdxml.XMLException XmlException;
alias stdxml.CheckException RecodeException;

Element[] elementsById(Element elem, string id)
{
	Element[] elems;
	foreach(e; elem.elements)
		if(e.tag && e.tag.name == id)
			elems ~= e;
	return elems;
}

string getAttribute(Element elem, string attr)
{
	if(string* s = attr in elem.tag.attr)
		return *s;
	return null;
}

void setAttribute(Element elem, string attr, string val)
{
	elem.tag.attr[attr] = val;
}

Element getRoot(Document doc)
{
	return doc;
}

Element getElement(Element e, string s)
{
	foreach(el; e.elements)
		if(el.tag.name == s)
			return el;
	return null;
}

Document newDocument(string root)
{
	return new Document(new stdxml.Tag(root));
}

Document readDocument(string text)
{
//	setHWBreakpopints();
	return new Document(text);
}

string[] writeDocument(Document doc)
{
	return doc.pretty(1);
}

alias stdxml.encode encode;
alias stdxml.decode decode;

}
else
{
private static import xmlp.pieceparser;
private static import xmlp.xmldom;
private static import xmlp.input;
private static import xmlp.delegater;
private static import xmlp.format;
private static import xmlp.except;
private static import inrange.recode;

alias xmlp.xmldom.Element Element;
alias xmlp.xmldom.Document Document;

alias xmlp.except.XmlException XmlException;
alias inrange.recode.RecodeException RecodeException;


Element[] elementsById(Element elem, string id)
{
	return elem.elementById(id);
}

string getAttribute(Element elem, string attr)
{
	return elem[attr];
}

void setAttribute(Element elem, string attr, string val)
{
	elem[attr] = val;
}

Element getRoot(Document doc)
{
	return doc.root;
}

Element getElement(Element e, string s)
{
	int idx = e.firstIndexOf(s);
	if(idx >= 0)
		if(Element el = cast(Element) e.children[idx])
			return el;
	return null;
}

Document newDocument(string root)
{
	return new Document(new Element(root));
}

Document readDocument(string text)
{
	auto spi = new xmlp.pieceparser.XmlParserInput(inrange.instring.dcharInputRange(text));
	Document doc = xmlp.pieceparser.XmlPieceParser.ReadDocument(spi);
	return doc;
}

string[] writeDocument(Document doc)
{
	xmlp.format.XmlFormat canit = new xmlp.format.XmlFormat();
	canit.indentAdjust = 1;
	// Pretty-print it
	string[] result;
	canit.canonput(doc, result);
	return result;
}

}
