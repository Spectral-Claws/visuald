// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2012 by Rainer Schuetze, All Rights Reserved
//
// Distributed under the Boost Software License, Version 1.0.
// See accompanying file LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt

module vdc.dmdserver.semvisitor;

import vdc.ivdserver : TypeReferenceKind;

import dmd.access;
import dmd.aggregate;
import dmd.apply;
import dmd.arraytypes;
import dmd.attrib;
import dmd.ast_node;
import dmd.builtin;
import dmd.cond;
import dmd.console;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dimport;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errors;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.mtype;
import dmd.objc;
import dmd.sapply;
import dmd.semantic2;
import dmd.semantic3;
import dmd.statement;
import dmd.staticassert;
import dmd.target;
import dmd.tokens;
import dmd.visitor;

import dmd.root.outbuffer;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.root.rootobject;

import std.algorithm;
import std.string;
import std.conv;
import stdext.array;
import stdext.denseset;
import core.stdc.string;

// walk the complete AST (declarations, statement and expressions)
// assumes being started on module/declaration level
extern(C++) class ASTVisitor : StoppableVisitor
{
	bool unconditional; // take both branches in conditional declarations/statements

	alias visit = StoppableVisitor.visit;

	DenseSet!ASTNode visited;

	void visitRecursive(T)(T node)
	{
		if (stop || !node || visited.contains(node))
			return;

		visited.insert(node);

		if (walkPostorder(node, this))
			stop = true;
	}

	void visitExpression(Expression expr)
	{
		visitRecursive(expr);
	}

	void visitStatement(Statement stmt)
	{
		visitRecursive(stmt);
	}

	void visitDeclaration(Dsymbol sym)
	{
		if (stop || !sym)
			return;

		sym.accept(this);
	}

	void visitParameter(Parameter p, Declaration decl)
	{
		visitType(p.parsedType);
		visitExpression(p.defaultArg);
		if (p.userAttribDecl)
			visit(p.userAttribDecl);
	}

	// default to being permissive
	override void visit(Parameter p)
	{
		visitParameter(p, null);
	}
	override void visit(TemplateParameter) {}

	// expressions
	override void visit(Expression expr)
	{
		if (expr.original && expr.original != expr)
			visitExpression(expr.original);
	}

	override void visit(ErrorExp errexp)
	{
		visit(cast(Expression)errexp);
	}

	override void visit(CastExp expr)
	{
		visitType(expr.parsedTo);
		if (expr.parsedTo != expr.to)
			visitType(expr.to);
		super.visit(expr);
	}

	override void visit(IsExp ie)
	{
		// TODO: has ident
		if (ie.targ)
			ie.targ.accept(this);
		if (ie.originaltarg && ie.originaltarg !is ie.targ)
			ie.originaltarg.accept(this);

		visit(cast(Expression)ie);
	}

	override void visit(DeclarationExp expr)
	{
		visitDeclaration(expr.declaration);
		visit(cast(Expression)expr);
	}

	override void visit(TypeExp expr)
	{
		visitType(expr.type);
		visit(cast(Expression)expr);
	}

	override void visit(FuncExp expr)
	{
		visitDeclaration(expr.fd);
		visitDeclaration(expr.td);

		visit(cast(Expression)expr);
	}

	override void visit(NewExp ne)
	{
		if (ne.member)
			ne.member.accept(this);

		visitType(ne.parsedType);
		if (ne.newtype != ne.parsedType)
			visitType(ne.newtype);

		super.visit(ne);
	}

	override void visit(ScopeExp expr)
	{
		if (auto ti = expr.sds.isTemplateInstance())
			visitTemplateInstance(ti);
		super.visit(expr);
	}

	override void visit(TraitsExp te)
	{
		if (te.args)
		{
			foreach(a; (*te.args))
				if (auto t = a.isType())
					visitType(t);
				else if (auto e = a.isExpression())
					visitExpression(e);
				//else if (auto s = a.isSymbol())
				//	visitSymbol(s);
		}

		super.visit(te);
	}

	void visitTemplateInstance(TemplateInstance ti)
	{
		if (ti.tiargs && ti.parsedArgs)
		{
			size_t args = min(ti.tiargs.dim, ti.parsedArgs.dim);
			for (size_t a = 0; a < args; a++)
				if (Type tip = (*ti.parsedArgs)[a].isType())
					visitType(tip);
		}
	}

	// types
	void visitType(Type type)
	{
		if (type)
			type.accept(this);
	}

	override void visit(Type t)
	{
	}

	override void visit(TypeSArray tsa)
	{
		visitExpression(tsa.dim);
		super.visit(tsa);
	}

	override void visit(TypeAArray taa)
	{
		if (taa.resolvedTo)
			visitType(taa.resolvedTo);
		else
		{
			visitType(taa.index);
			super.visit(taa);
		}
	}

	override void visit(TypeNext tn)
	{
		visitType(tn.next);
		super.visit(tn);
	}

	override void visit(TypeTypeof t)
	{
		visitExpression(t.exp);
		super.visit(t);
	}

	// symbols
	override void visit(Dsymbol) {}

	override void visit(ScopeDsymbol scopesym)
	{
		super.visit(scopesym);

		// optimize to only visit members in approriate source range
		size_t mcnt = scopesym.members ? scopesym.members.dim : 0;
		for (size_t m = 0; !stop && m < mcnt; m++)
		{
			Dsymbol s = (*scopesym.members)[m];
			s.accept(this);
		}
	}

	// declarations
	override void visit(VarDeclaration decl)
	{
		visitType(decl.parsedType);
		if (decl.originalType != decl.parsedType)
			visitType(decl.originalType);
		if (decl.type != decl.originalType && decl.type != decl.parsedType)
			visitType(decl.type); // not yet semantically analyzed (or a template declaration)

		visit(cast(Declaration)decl);

		if (!stop && decl._init)
			decl._init.accept(this);
	}

	override void visit(AliasDeclaration ad)
	{
		visitType(ad.originalType);
		super.visit(ad);
	}

	override void visit(AttribDeclaration decl)
	{
		visit(cast(Declaration)decl);

		if (!stop)
		{
			if (unconditional)
			{
				if (decl.decl)
					foreach(d; *decl.decl)
						if (!stop)
							d.accept(this);
			}
			else if (auto inc = decl.include(null))
				foreach(d; *inc)
					if (!stop)
						d.accept(this);
		}
	}

	override void visit(UserAttributeDeclaration decl)
	{
		if (decl.atts)
			foreach(e; *decl.atts)
				visitExpression(e);

		super.visit(decl);
	}

	override void visit(ConditionalDeclaration decl)
	{
		if (!stop && decl.condition)
			decl.condition.accept(this);

		visit(cast(AttribDeclaration)decl);

		if (!stop && unconditional && decl.elsedecl)
			foreach(d; *decl.elsedecl)
				if (!stop)
					d.accept(this);
	}

	override void visit(FuncDeclaration decl)
	{
		visit(cast(Declaration)decl);

		// function declaration only
		if (auto tf = decl.type ? decl.type.isTypeFunction() : null)
		{
			if (tf.parameterList && tf.parameterList.parameters)
				foreach(i, p; *tf.parameterList.parameters)
					if (!stop)
					{
						if (decl.parameters && i < decl.parameters.dim)
							visitParameter(p, (*decl.parameters)[i]);
						else
							p.accept(this);
					}
		}
		else if (decl.parameters)
		{
			foreach(p; *decl.parameters)
				if (!stop)
					p.accept(this);
		}

		if (decl.frequires)
			foreach(s; *decl.frequires)
				visitStatement(s);
		if (decl.fensures)
			foreach(e; *decl.fensures)
				visitStatement(e.ensure); // TODO: check result ident

		visitStatement(decl.frequire);
		visitStatement(decl.fensure);
		visitStatement(decl.fbody);
	}

	override void visit(ClassDeclaration cd)
	{
		if (cd.baseclasses)
			foreach (bc; *(cd.baseclasses))
				visitType(bc.parsedType);

		super.visit(cd);
	}

	// condition
	override void visit(Condition) {}

	override void visit(StaticIfCondition cond)
	{
		visitExpression(cond.exp);
		visit(cast(Condition)cond);
	}

	// initializer
	override void visit(Initializer) {}

	override void visit(ExpInitializer einit)
	{
		visitExpression(einit.exp);
	}

	override void visit(VoidInitializer vinit)
	{
	}

	override void visit(ErrorInitializer einit)
	{
		if (einit.original)
			einit.original.accept(this);
	}

	override void visit(StructInitializer sinit)
	{
		foreach (i, const id; sinit.field)
			if (auto iz = sinit.value[i])
				iz.accept(this);
	}

	override void visit(ArrayInitializer ainit)
	{
		foreach (i, ex; ainit.index)
		{
			if (ex)
				ex.accept(this);
			if (auto iz = ainit.value[i])
				iz.accept(this);
		}
	}

	// statements
	override void visit(Statement stmt)
	{
		if (stmt.original)
			visitStatement(stmt.original);
	}

	override void visit(ExpStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(ConditionalStatement stmt)
	{
		if (!stop && stmt.condition)
		{
			stmt.condition.accept(this);

			if (unconditional)
			{
				visitStatement(stmt.ifbody);
				visitStatement(stmt.elsebody);
			}
			else if (stmt.condition.include(null))
				visitStatement(stmt.ifbody);
			else
				visitStatement(stmt.elsebody);
		}
		visit(cast(Statement)stmt);
	}

	override void visit(CompileStatement stmt)
	{
		if (stmt.exps)
			foreach(e; *stmt.exps)
				if (!stop)
					e.accept(this);
		visit(cast(Statement)stmt);
	}

	override void visit(WhileStatement stmt)
	{
		visitExpression(stmt.condition);
		visit(cast(Statement)stmt);
	}

	override void visit(DoStatement stmt)
	{
		visitExpression(stmt.condition);
		visit(cast(Statement)stmt);
	}

	override void visit(ForStatement stmt)
	{
		visitExpression(stmt.condition);
		visitExpression(stmt.increment);
		visit(cast(Statement)stmt);
	}

	override void visit(ForeachStatement stmt)
	{
		if (stmt.parameters)
			foreach(p; *stmt.parameters)
				if (!stop)
					p.accept(this);
		visitExpression(stmt.aggr);
		visit(cast(Statement)stmt);
	}

	override void visit(ForeachRangeStatement stmt)
	{
		if (!stop && stmt.prm)
			stmt.prm.accept(this);
		visitExpression(stmt.lwr);
		visitExpression(stmt.upr);
		visit(cast(Statement)stmt);
	}

	override void visit(IfStatement stmt)
	{
		// prm converted to DeclarationExp as part of condition
		//if (!stop && stmt.prm)
		//	stmt.prm.accept(this);
		visitExpression(stmt.condition);
		visit(cast(Statement)stmt);
	}

	override void visit(PragmaStatement stmt)
	{
		if (!stop && stmt.args)
			foreach(a; *stmt.args)
				if (!stop)
					a.accept(this);
		visit(cast(Statement)stmt);
	}

	override void visit(StaticAssertStatement stmt)
	{
		visitExpression(stmt.sa.exp);
		visitExpression(stmt.sa.msg);
		visit(cast(Statement)stmt);
	}

	override void visit(SwitchStatement stmt)
	{
		visitExpression(stmt.condition);
		visit(cast(Statement)stmt);
	}

	override void visit(CaseStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(CaseRangeStatement stmt)
	{
		visitExpression(stmt.first);
		visitExpression(stmt.last);
		visit(cast(Statement)stmt);
	}

	override void visit(GotoCaseStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(ReturnStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(SynchronizedStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(WithStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(TryCatchStatement stmt)
	{
		// variables not looked at by PostorderStatementVisitor
		if (!stop && stmt.catches)
			foreach(c; *stmt.catches)
			{
				if (c.var)
					visitDeclaration(c.var);
				else
					visitType(c.parsedType);
			}

		visit(cast(Statement)stmt);
	}

	override void visit(ThrowStatement stmt)
	{
		visitExpression(stmt.exp);
		visit(cast(Statement)stmt);
	}

	override void visit(ImportStatement stmt)
	{
		if (!stop && stmt.imports)
			foreach(i; *stmt.imports)
				visitDeclaration(i);
		visit(cast(Statement)stmt);
	}
}

extern(C++) class FindASTVisitor : ASTVisitor
{
	const(char*) filename;
	int startLine;
	int startIndex;
	int endLine;
	int endIndex;

	alias visit = ASTVisitor.visit;
	RootObject found;
	ScopeDsymbol foundScope;

	this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
	{
		this.filename = filename;
		this.startLine = startLine;
		this.startIndex = startIndex;
		this.endLine = endLine;
		this.endIndex = endIndex;
	}

	void foundNode(RootObject obj)
	{
		if (obj)
		{
			found = obj;
			// do not stop until the scope is also set
		}
	}

	void checkScope(ScopeDsymbol sc)
	{
		if (found && sc && !foundScope)
		{
			foundScope = sc;
			stop = true;
		}
	}

	bool foundExpr(Expression expr)
	{
		if (auto se = expr.isScopeExp())
			foundNode(se.sds);
		else if (auto ve = expr.isVarExp())
			foundNode(ve.var);
		else if (auto te = expr.isTypeExp())
			foundNode(te.type);
		else
			return false;
		return true;
	}

	bool foundResolved(Expression expr)
	{
		if (!expr)
			return false;
		CommaExp ce;
		while ((ce = expr.isCommaExp()) !is null)
		{
			if (foundExpr(ce.e1))
				return true;
			expr = ce.e2;
		}
		return foundExpr(expr);
	}

	bool matchIdentifier(ref const Loc loc, Identifier ident)
	{
		if (ident)
			if (loc.filename is filename)
				if (loc.linnum == startLine && loc.linnum == endLine)
					if (loc.charnum <= startIndex && loc.charnum + ident.toString().length >= endIndex)
						return true;
		return false;
	}

	bool visitPackages(Module mod, IdentifiersAtLoc* packages)
	{
		if (!mod || !packages)
			return false;

		Package pkg = mod.parent ? mod.parent.isPackage() : null;
		for (size_t p; pkg && p < packages.dim; p++)
		{
			size_t q = packages.dim - 1 - p;
			if (!found && matchIdentifier((*packages)[q].loc, (*packages)[q].ident))
			{
				foundNode(pkg);
				return true;
			}
			pkg = pkg.parent ? pkg.parent.isPackage() : null;
		}
		return false;
	}

	bool matchLoc(ref const(Loc) loc, int len)
	{
		if (loc.filename is filename)
			if (loc.linnum == startLine && loc.linnum == endLine)
				if (loc.charnum <= startIndex && loc.charnum + len >= endIndex)
					return true;
		return false;
	}

	override void visit(Dsymbol sym)
	{
		if (sym.isFuncLiteralDeclaration())
			return;
		if (!found && matchIdentifier(sym.loc, sym.ident))
			foundNode(sym);
	}

	override void visit(StaticAssert sa)
	{
		visitExpression(sa.exp);
		visitExpression(sa.msg);
		super.visit(sa);
	}

	override void visitParameter(Parameter sym, Declaration decl)
	{
		super.visitParameter(sym, decl);
		if (!found && matchIdentifier(sym.ident.loc, sym.ident))
			foundNode(decl ? decl : sym);
	}

	override void visit(Module mod)
	{
		if (mod.md)
		{
			visitPackages(mod, mod.md.packages);

			if (!found && matchIdentifier(mod.md.loc, mod.md.id))
				foundNode(mod);
		}
		visit(cast(Package)mod);
	}

	override void visit(Import imp)
	{
		visitPackages(imp.mod, imp.packages);

		if (!found && matchIdentifier(imp.loc, imp.id))
			foundNode(imp.mod);

		for (int n = 0; !found && n < imp.names.dim; n++)
			if (matchIdentifier(imp.names[n].loc, imp.names[n].ident) ||
				matchIdentifier(imp.aliases[n].loc, imp.aliases[n].ident))
				if (n < imp.aliasdecls.dim)
					foundNode(imp.aliasdecls[n]);

		// symbol has ident of first package, so don't forward
	}

	override void visit(DVCondition cond)
	{
		if (!found && matchIdentifier(cond.loc, cond.ident))
			foundNode(cond);
	}

	override void visit(Expression expr)
	{
		super.visit(expr);
	}

	override void visit(CompoundStatement cs)
	{
		// optimize to only visit members in approriate source range
		size_t scnt = cs.statements ? cs.statements.dim : 0;
		for (size_t i = 0; i < scnt && !stop; i++)
		{
			Statement s = (*cs.statements)[i];
			if (!s)
				continue;
			if (visited.contains(s))
				continue;

			if (s.loc.filename)
			{
				if (s.loc.filename !is filename || s.loc.linnum > endLine)
					continue;
				Loc endloc;
				if (auto ss = s.isScopeStatement())
					endloc = ss.endloc;
				else if (auto ws = s.isWhileStatement())
					endloc = ws.endloc;
				else if (auto ds = s.isDoStatement())
					endloc = ds.endloc;
				else if (auto fs = s.isForStatement())
					endloc = fs.endloc;
				else if (auto fs = s.isForeachStatement())
					endloc = fs.endloc;
				else if (auto fs = s.isForeachRangeStatement())
					endloc = fs.endloc;
				else if (auto ifs = s.isIfStatement())
					endloc = ifs.endloc;
				else if (auto ws = s.isWithStatement())
					endloc = ws.endloc;
				if (endloc.filename && endloc.linnum < startLine)
					continue;
			}
			s.accept(this);
		}
		visit(cast(Statement)cs);
	}

	override void visit(ScopeDsymbol scopesym)
	{
		// optimize to only visit members in approriate source range
		// unfortunately, some members don't have valid locations
		size_t mcnt = scopesym.members ? scopesym.members.dim : 0;
		for (size_t m = 0; m < mcnt && !stop; m++)
		{
			Dsymbol s = (*scopesym.members)[m];
			if (s.isTemplateInstance)
				continue;
			if (s.loc.filename)
			{
				if (s.loc.filename !is filename || s.loc.linnum > endLine)
					continue;
				Loc endloc;
				if (auto fd = s.isFuncDeclaration())
					endloc = fd.endloc;
				if (endloc.filename && endloc.linnum < startLine)
					continue;
			}
			s.accept(this);
		}
		checkScope(scopesym);
	}

	override void visit(ScopeStatement ss)
	{
		visit(cast(Statement)ss);
		checkScope(ss.scopesym);
	}

	override void visit(TemplateInstance ti)
	{
		// skip members added by semantic
		visit(cast(ScopeDsymbol)ti);
	}

	override void visit(TemplateDeclaration td)
	{
		if (!found && td.ident)
			if (matchIdentifier(td.loc, td.ident))
				foundNode(td);

		foreach(ti; td.instances)
			if (!stop)
				visit(ti);

		visit(cast(ScopeDsymbol)td);
	}

	override void visitTemplateInstance(TemplateInstance ti)
	{
		if (!found && ti.name)
			if (matchIdentifier(ti.loc, ti.name))
				foundNode(ti);

		super.visitTemplateInstance(ti);
	}

	override void visit(CallExp expr)
	{
		super.visit(expr);
	}

	override void visit(SymbolExp expr)
	{
		if (!found && expr.var)
			if (matchIdentifier(expr.loc, expr.var.ident))
				foundNode(expr);
		super.visit(expr);
	}

	override void visit(IdentifierExp expr)
	{
		if (!found && expr.ident)
		{
			if (matchIdentifier(expr.loc, expr.ident))
			{
				if (expr.type)
					foundNode(expr.type);
				else if (expr.resolvedTo)
					foundResolved(expr.resolvedTo);
			}
		}
		visit(cast(Expression)expr);
	}

	override void visit(DotIdExp de)
	{
		if (!found)
			if (de.ident)
				if (matchIdentifier(de.identloc, de.ident))
				{
					if (!de.type && de.resolvedTo && !de.resolvedTo.isErrorExp())
						foundResolved(de.resolvedTo);
					else
						foundNode(de);
				}
	}

	override void visit(DotExp de)
	{
		if (!found)
		{
			// '.' of erroneous DotIdExp
			if (matchLoc(de.loc, 2))
				foundNode(de);
		}
		super.visit(de);
	}

	override void visit(DotTemplateExp dte)
	{
		if (!found && dte.td && dte.td.ident)
			if (matchIdentifier(dte.identloc, dte.td.ident))
				foundNode(dte);
		super.visit(dte);
	}

	override void visit(TemplateExp te)
	{
		if (!found && te.td && te.td.ident)
			if (matchIdentifier(te.identloc, te.td.ident))
				foundNode(te);
		super.visit(te);
	}

	override void visit(DotVarExp dve)
	{
		if (!found && dve.var && dve.var.ident)
			if (matchIdentifier(dve.varloc.filename ? dve.varloc : dve.loc, dve.var.ident))
				foundNode(dve);
	}

	override void visit(EnumDeclaration ed)
	{
		if (!found && ed.ident)
			if (matchIdentifier(ed.loc, ed.ident))
				foundNode(ed);

		visit(cast(ScopeDsymbol)ed);
	}

	override void visit(AggregateDeclaration ad)
	{
		if (!found && ad.ident)
			if (matchIdentifier(ad.loc, ad.ident))
				foundNode(ad);

		visit(cast(ScopeDsymbol)ad);
	}

	override void visit(FuncDeclaration decl)
	{
		super.visit(decl);

		checkScope(decl.scopesym);

		visitType(decl.originalType);
	}

	override void visit(TypeQualified tq)
	{
		foreach (i, id; tq.idents)
		{
			RootObject obj = id;
			if (obj.dyncast() == DYNCAST.identifier)
			{
				auto ident = cast(Identifier)obj;
				if (matchIdentifier(id.loc, ident))
					if (tq.parentScopes.dim > i + 1)
						foundNode(tq.parentScopes[i + 1]);
			}
		}
		super.visit(tq);
	}

	override void visit(TypeIdentifier otype)
	{
		if (found)
			return;

		for (TypeIdentifier ti = otype; ti; ti = ti.copiedFrom)
			if (ti.parentScopes.dim)
			{
				otype = ti;
				break;
			}

		if (matchIdentifier(otype.loc, otype.ident))
		{
			if (otype.parentScopes.dim > 0)
				foundNode(otype.parentScopes[0]);
			else
				foundNode(otype);
		}
		super.visit(otype);
	}

	override void visit(TypeInstance ti)
	{
		if (found)
			return;

		for (TypeInstance cti = ti; cti; cti = cti.copiedFrom)
			if (cti.parentScopes.dim)
			{
				ti = cti;
				break;
			}

		if (ti.tempinst && matchIdentifier(ti.loc, ti.tempinst.name))
		{
			if (ti.parentScopes.dim > 0)
				foundNode(ti.parentScopes[0]);
			return;
		}
		visitTemplateInstance(ti.tempinst);
		super.visit(ti);
	}
}

RootObject _findAST(Dsymbol sym, const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
{
	scope FindASTVisitor fav = new FindASTVisitor(filename, startLine, startIndex, endLine, endIndex);
	sym.accept(fav);

	return fav.found;
}

RootObject findAST(Module mod, int startLine, int startIndex, int endLine, int endIndex)
{
	auto filename = mod.srcfile.toChars();
	return _findAST(mod, filename, startLine, startIndex, endLine, endIndex);
}

////////////////////////////////////////////////////////////////////////////////

extern(C++) class FindTipVisitor : FindASTVisitor
{
	string tip;

	alias visit = FindASTVisitor.visit;

	this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
	{
		super(filename, startLine, startIndex, endLine, endIndex);
	}

	void visitCallExpression(CallExp expr)
	{
		if (!found)
		{
			// replace function type with actual
			visitExpression(expr);
			if (found is expr.e1)
			{
				foundNode(expr);
			}
		}
	}

	override void foundNode(RootObject obj)
	{
		found = obj;
		if (obj)
		{
			tip = tipForObject(obj);
			stop = true;
		}
	}
}

string quoteCode(bool quote, string s)
{
	if (!quote || s.empty)
		return s;
	return "`" ~ s ~ "`";
}

struct TipData
{
	string kind;
	string code;
	string doc;
}

string tipForObject(RootObject obj)
{
	TipData tip = tipDataForObject(obj);

	string txt;
	if (tip.kind.length)
		txt = "(" ~ tip.kind ~ ")";
	if (tip.code.length && txt.length)
		txt ~= " ";
	txt ~= quoteCode(true, tip.code);
	if (tip.doc.length && txt.length)
		txt ~= "\n\n";
	if (tip.doc.length)
		txt ~= strip(tip.doc);
	return txt;
}

TipData tipDataForObject(RootObject obj)
{
	TipData tipForDeclaration(Declaration decl)
	{
		if (auto func = decl.isFuncDeclaration())
		{
			OutBuffer buf;
			if (decl.type && decl.type.isTypeFunction())
				functionToBufferWithIdent(decl.type.toTypeFunction(), &buf, decl.toPrettyChars());
			else
				buf.writestring(decl.toPrettyChars());
			auto res = buf.extractSlice(); // take ownership
			return TipData("", cast(string)res);
		}

		bool fqn = true;
		string txt;
		string kind;
		if (decl.isParameter())
		{
			if (decl.parent)
				if (auto fd = decl.parent.isFuncDeclaration())
					if (fd.ident.toString().startsWith("__foreachbody"))
						kind = "foreach variable";
			if (kind.empty)
				kind = "parameter";
			fqn = false;
		}
		else if (auto em = decl.isEnumMember())
		{
			kind = "enum value";
			txt = decl.toPrettyChars(fqn).to!string;
			if (em.origValue)
				txt ~= " = " ~ cast(string)em.origValue.toString();
			return TipData(kind, txt);
		}
		else if (decl.storage_class & STC.manifest)
			kind = "constant";
		else if (decl.isAliasDeclaration())
			kind = "alias";
		else if (decl.isField())
			kind = "field";
		else if (decl.semanticRun >= PASS.semanticdone) // avoid lazy semantic analysis
		{
			if (!decl.isDataseg() && !decl.isCodeseg())
			{
				kind = "local variable";
				fqn = false;
			}
			else if (decl.isThreadlocal())
				kind = "thread local global";
			else if (decl.type && decl.type.isShared())
				kind = "shared global";
			else if (decl.type && decl.type.isConst())
				kind = "constant global";
			else if (decl.type && decl.type.isImmutable())
				kind = "immutable global";
			else if (decl.type && decl.type.ty != Terror)
				kind = "__gshared global";
		}

		if (decl.type)
			txt ~= to!string(decl.type.toPrettyChars(true)) ~ " ";
		txt ~= to!string(fqn ? decl.toPrettyChars(fqn) : decl.toChars());
		if (decl.storage_class & STC.manifest)
			if (auto var = decl.isVarDeclaration())
				if (var._init)
					txt ~= " = " ~ var._init.toString();
		if (auto ad = decl.isAliasDeclaration())
			if (ad.aliassym)
			{
				TipData tip = tipDataForObject(ad.aliassym);
				if (tip.kind.length)
					kind = "alias " ~ tip.kind;
				if (tip.code.length)
					txt ~= " = " ~ tip.code;
			}
		return TipData(kind, txt);
	}

	TipData tipForType(Type t)
	{
		string kind;
		if (t.isTypeIdentifier())
			kind = "unresolved type";
		else if (auto tc = t.isTypeClass())
			kind = tc.sym.isInterfaceDeclaration() ? "interface" : "class";
		else if (auto ts = t.isTypeStruct())
			kind = ts.sym.isUnionDeclaration() ? "union" : "struct";
		else
			kind = t.kind().to!string;
		string txt = t.toPrettyChars(true).to!string;
		string doc;
		if (auto sym = typeSymbol(t))
			if (sym.comment)
				doc = sym.comment.to!string;
		return TipData(kind, txt, doc);
	}

	TipData tipForDotIdExp(DotIdExp die)
	{
		auto resolvedTo = die.resolvedTo;
		bool isConstant = resolvedTo.isConstantExpr();
		Expression e1;
		if (!isConstant && !resolvedTo.isArrayLengthExp() && die.type)
		{
			e1 = isAALenCall(resolvedTo);
			if (!e1 && die.ident == Id.ptr && resolvedTo.isCastExp())
				e1 = resolvedTo;
			if (!e1 && resolvedTo.isTypeExp())
				return tipForType(die.type);
		}
		if (!e1)
			e1 = die.e1;
		string kind = isConstant ? "constant" : "field";
		string tip = resolvedTo.type.toPrettyChars(true).to!string ~ " ";
		tip ~= e1.type && !e1.isConstantExpr() ? die.e1.type.toPrettyChars(true).to!string : e1.toString();
		tip ~= "." ~ die.ident.toString();
		if (isConstant)
			tip ~= " = " ~ resolvedTo.toString();
		return TipData(kind, tip);
	}

	TipData tip;
	const(char)* doc;

	if (auto t = obj.isType())
	{
		tip = tipForType(t.mutableOf().unSharedOf());
	}
	else if (auto e = obj.isExpression())
	{
		switch(e.op)
		{
			case TOK.variable:
			case TOK.symbolOffset:
				tip = tipForDeclaration((cast(SymbolExp)e).var);
				doc = (cast(SymbolExp)e).var.comment;
				break;
			case TOK.dotVariable:
				tip = tipForDeclaration((cast(DotVarExp)e).var);
				doc = (cast(DotVarExp)e).var.comment;
				break;
			case TOK.dotIdentifier:
				auto die = e.isDotIdExp();
				if (die.resolvedTo && die.resolvedTo.type)
				{
					tip = tipForDotIdExp(die);
					break;
				}
				goto default;
			default:
				if (e.type)
					tip = tipForType(e.type);
				break;
		}
	}
	else if (auto s = obj.isDsymbol())
	{
		if (auto imp = s.isImport())
			if (imp.mod)
				s = imp.mod;
		if (auto decl = s.isDeclaration())
			tip = tipForDeclaration(decl);
		else
		{
			tip.kind = s.kind().to!string;
			tip.code = s.toPrettyChars(true).to!string;
		}
		if (s.comment)
			doc = s.comment;
	}
	else if (auto p = obj.isParameter())
	{
		if (auto t = p.type ? p.type : p.parsedType)
			tip.code = t.toPrettyChars(true).to!string;
		if (p.ident && tip.code.length)
			tip.code ~= " ";
		if (p.ident)
			tip.code ~= p.ident.toString;
		tip.kind = "parameter";
	}
	if (!tip.code.length)
	{
		tip.code = obj.toString().dup;
	}
	// append doc
	if (doc)
		tip.doc = cast(string)doc[0..strlen(doc)];
	return tip;
}

string findTip(Module mod, int startLine, int startIndex, int endLine, int endIndex)
{
	auto filename = mod.srcfile.toChars();
	scope FindTipVisitor ftv = new FindTipVisitor(filename, startLine, startIndex, endLine, endIndex);
	mod.accept(ftv);

	return ftv.tip;
}

////////////////////////////////////////////////////////////////

extern(C++) class FindDefinitionVisitor : FindASTVisitor
{
	Loc loc;

	alias visit = FindASTVisitor.visit;

	this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
	{
		super(filename, startLine, startIndex, endLine, endIndex);
	}

	override void foundNode(RootObject obj)
	{
		found = obj;
		if (obj)
		{
			if (auto t = obj.isType())
			{
				if (auto sym = typeSymbol(t))
					loc = sym.loc;
			}
			else if (auto e = obj.isExpression())
			{
				switch(e.op)
				{
					case TOK.variable:
					case TOK.symbolOffset:
						loc = (cast(SymbolExp)e).var.loc;
						break;
					case TOK.dotVariable:
						loc = (cast(DotVarExp)e).var.loc;
						break;
					default:
						loc = e.loc;
						break;
				}
			}
			else if (auto s = obj.isDsymbol())
			{
				loc = s.loc;
			}
		}
	}
}

string findDefinition(Module mod, ref int line, ref int index)
{
	auto filename = mod.srcfile.toChars();
	scope FindDefinitionVisitor fdv = new FindDefinitionVisitor(filename, line, index, line, index + 1);
	mod.accept(fdv);

	if (!fdv.loc.filename)
		return null;
	line = fdv.loc.linnum;
	index = fdv.loc.charnum;
	return to!string(fdv.loc.filename);
}

////////////////////////////////////////////////////////////////////////////////

Loc[] findBinaryIsInLocations(Module mod)
{
	extern(C++) class BinaryIsInVisitor : ASTVisitor
	{
		Loc[] locdata;
		const(char)* filename;

		alias visit = ASTVisitor.visit;

		final void addLocation(const ref Loc loc)
		{
			if (loc.filename is filename)
				locdata ~= loc;
		}

		override void visit(InExp e)
		{
			addLocation(e.oploc);
			super.visit(e);
		}
		override void visit(IdentityExp e)
		{
			addLocation(e.oploc);
			super.visit(e);
		}
	}

	scope BinaryIsInVisitor biiv = new BinaryIsInVisitor;
	biiv.filename = mod.srcfile.toChars();
	biiv.unconditional = true;
	mod.accept(biiv);

	return biiv.locdata;
}

////////////////////////////////////////////////////////////////////////////////
struct IdTypePos
{
	int type;
	int line;
	int col;
}

alias FindIdentifierTypesResult = IdTypePos[][const(char)[]];

FindIdentifierTypesResult findIdentifierTypes(Module mod)
{
	extern(C++) class IdentifierTypesVisitor : ASTVisitor
	{
		FindIdentifierTypesResult idTypes;
		const(char)* filename;

		alias visit = ASTVisitor.visit;

		extern(D)
		final void addTypePos(const(char)[] ident, int type, int line, int col)
		{
			if (auto pid = ident in idTypes)
			{
				// merge sorted
				import std.range;
				auto a = assumeSorted!"a.line < b.line || (a.line == b.line && a.col < b.col)"(*pid);
				auto itp = IdTypePos(type, line, col);
				auto sections = a.trisect(itp);
				if (!sections[1].empty)
				{} // do not overwrite identical location
				else if (!sections[2].empty && sections[2][0].type == type) // upperbound
					sections[2][0] = itp; // extend lowest location
				else if (sections[0].empty || sections[0][$-1].type != type) // lowerbound
					// insert new entry if last lower location is different type
					*pid = (*pid)[0..sections[0].length] ~ itp ~ (*pid)[sections[0].length..$];
			}
			else
				idTypes[ident] = [IdTypePos(type, line, col)];
		}

		void addIdent(ref const Loc loc, Identifier ident, int type)
		{
			if (ident && loc.filename is filename)
				addTypePos(ident.toString(), type, loc.linnum, loc.charnum);
		}

		void addIdentByType(ref const Loc loc, Identifier ident, Type t)
		{
			if (ident && t && loc.filename is filename)
			{
				int type = TypeReferenceKind.Unknown;
				switch (t.ty)
				{
					case Tstruct:   type = TypeReferenceKind.Struct; break;
					//case Tunion:  type = TypeReferenceKind.Union; break;
					case Tclass:    type = TypeReferenceKind.Class; break;
					case Tenum:     type = TypeReferenceKind.Enum; break;
					default: break;
				}
				if (type != TypeReferenceKind.Unknown)
					addTypePos(ident.toString(), type, loc.linnum, loc.charnum);
			}
		}

		void addPackages(IdentifiersAtLoc* packages)
		{
			if (packages)
				for (size_t p; p < packages.dim; p++)
					addIdent((*packages)[p].loc, (*packages)[p].ident, TypeReferenceKind.Package);
		}

		void addDeclaration(ref const Loc loc, Declaration decl)
		{
			auto ident = decl.ident;
			if (auto func = decl.isFuncDeclaration())
			{
				if (func.isFuncLiteralDeclaration())
					return; // ignore generated identifiers
				auto p = decl.toParent2;
				if (p && p.isAggregateDeclaration)
					addIdent(loc, ident, TypeReferenceKind.Method);
				else
					addIdent(loc, ident, TypeReferenceKind.Function);
			}
			else if (decl.isParameter())
				addIdent(loc, ident, TypeReferenceKind.ParameterVariable);
			else if (decl.isEnumMember())
				addIdent(loc, ident, TypeReferenceKind.EnumValue);
			else if (decl.storage_class & STC.manifest)
				addIdent(loc, ident, TypeReferenceKind.Constant);
			else if (decl.isAliasDeclaration())
				addIdent(loc, ident, TypeReferenceKind.Alias);
			else if (decl.isField())
				addIdent(loc, ident, TypeReferenceKind.MemberVariable);
			else if (!decl.isDataseg() && !decl.isCodeseg())
				addIdent(loc, ident, TypeReferenceKind.LocalVariable);
			else if (decl.isThreadlocal())
				addIdent(loc, ident, TypeReferenceKind.TLSVariable);
			else if (decl.type && decl.type.isShared())
				addIdent(loc, ident, TypeReferenceKind.SharedVariable);
			else
				addIdent(loc, ident, TypeReferenceKind.GSharedVariable);
		}

		override void visit(TypeQualified tid)
		{
			foreach (i, id; tid.idents)
			{
				RootObject obj = id;
				if (obj.dyncast() == DYNCAST.identifier)
				{
					auto ident = cast(Identifier)obj;
					if (tid.parentScopes.dim > i + 1)
						addObject(id.loc, tid.parentScopes[i + 1]);
				}
			}
			super.visit(tid);
		}

		override void visit(TypeIdentifier tid)
		{
			while (tid.copiedFrom)
			{
				if (tid.parentScopes.dim > 0)
					break;
				tid = tid.copiedFrom;
			}
			if (tid.parentScopes.dim > 0)
				addObject(tid.loc, tid.parentScopes[0]);
			super.visit(tid);
		}

		override void visit(TypeInstance tid)
		{
			if (!tid.tempinst)
				return;
			if (tid.parentScopes.dim > 0)
				addObject(tid.loc, tid.parentScopes[0]);
			super.visit(tid);
		}

		void addObject(ref const Loc loc, RootObject obj)
		{
			if (auto t = obj.isType())
				visitType(t);
			else if (auto s = obj.isDsymbol())
			{
				if (auto imp = s.isImport())
					if (imp.mod)
						s = imp.mod;
				addSymbol(loc, s);
			}
			else if (auto e = obj.isExpression())
				e.accept(this);
		}

		void addSymbol(ref const Loc loc, Dsymbol sym)
		{
			if (auto decl = sym.isDeclaration())
				addDeclaration(loc, decl);
			else if (sym.isUnionDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Union);
			else if (sym.isStructDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Struct);
			else if (sym.isInterfaceDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Interface);
			else if (sym.isClassDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Class);
			else if (sym.isEnumDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Enum);
			else if (sym.isModule())
				addIdent(loc, sym.ident, TypeReferenceKind.Module);
			else if (sym.isPackage())
				addIdent(loc, sym.ident, TypeReferenceKind.Package);
			else if (sym.isTemplateDeclaration())
				addIdent(loc, sym.ident, TypeReferenceKind.Template);
			else
				addIdent(loc, sym.ident, TypeReferenceKind.Variable);
		}

		override void visit(Dsymbol sym)
		{
			addSymbol(sym.loc, sym);
		}

		override void visitParameter(Parameter sym, Declaration decl)
		{
			super.visitParameter(sym, decl);
			addIdent(sym.ident.loc, sym.ident, TypeReferenceKind.ParameterVariable);
		}

		override void visit(Module mod)
		{
			if (mod.md)
			{
				addPackages(mod.md.packages);
				addIdent(mod.md.loc, mod.md.id, TypeReferenceKind.Module);
			}
			visit(cast(Package)mod);
		}

		override void visit(Import imp)
		{
			addPackages(imp.packages);

			addIdent(imp.loc, imp.id, TypeReferenceKind.Module);

			for (int n = 0; n < imp.names.dim; n++)
			{
				addIdent(imp.names[n].loc, imp.names[n].ident, TypeReferenceKind.Alias);
				if (imp.aliases[n].ident && n < imp.aliasdecls.dim)
					addDeclaration(imp.aliases[n].loc, imp.aliasdecls[n]);
			}
			// symbol has ident of first package, so don't forward
		}

		override void visit(DebugCondition cond)
		{
			addIdent(cond.loc, cond.ident, TypeReferenceKind.VersionIdentifier);
		}

		override void visit(VersionCondition cond)
		{
			addIdent(cond.loc, cond.ident, TypeReferenceKind.VersionIdentifier);
		}

		override void visit(SymbolExp expr)
		{
			if (expr.var && expr.var.ident)
				addDeclaration(expr.loc, expr.var);
			super.visit(expr);
		}

		void addIdentExp(Expression expr, Type t)
		{
			if (auto ie = expr.isIdentifierExp())
			{
				addIdentByType(ie.loc, ie.ident, t);
			}
			else if (auto die = expr.isDotIdExp())
			{
				addIdentByType(die.ident.loc, die.ident, t);
			}
		}

		void addOriginal(Expression expr, Type t)
		{
			for (auto ce = expr.isCommaExp(); ce; ce = expr.isCommaExp())
			{
				addIdentExp(ce.e1, t);
				expr = ce.e2;
			}
			addIdentExp(expr, t);
		}

		override void visit(TypeExp expr)
		{
			if (expr.original && expr.type)
				addOriginal(expr.original, expr.type);

			super.visit(expr);
		}

		override void visit(IdentifierExp expr)
		{
			if (expr.resolvedTo)
				if (auto se = expr.resolvedTo.isScopeExp())
					addSymbol(expr.loc, se.sds);

//			if (expr.type)
//				addIdentByType(expr.loc, expr.ident, expr.type);
//			else if (expr.original && expr.original.type)
//				addIdentByType(expr.loc, expr.ident, expr.original.type);
//			else
				super.visit(expr);
		}

		override void visit(DotIdExp expr)
		{
			auto orig = expr.resolvedTo;
			if (orig && orig.type && orig.isConstantExpr())
				addIdent(expr.identloc, expr.ident, TypeReferenceKind.Constant);
			else if (orig && orig.type &&
					 (orig.isArrayLengthExp() || orig.isAALenCall() || (expr.ident == Id.ptr && orig.isCastExp())))
				addIdent(expr.identloc, expr.ident, TypeReferenceKind.MemberVariable);
			else
				super.visit(expr);
		}

		override void visit(DotVarExp dve)
		{
			if (dve.var && dve.var.ident)
				addDeclaration(dve.varloc.filename ? dve.varloc : dve.loc, dve.var);
			super.visit(dve);
		}

		override void visit(EnumDeclaration ed)
		{
			addIdent(ed.loc, ed.ident, TypeReferenceKind.Enum);
			super.visit(ed);
		}

		override void visit(FuncDeclaration decl)
		{
			super.visit(decl);

			if (decl.originalType)
			{
				auto ot = decl.originalType ? decl.originalType.isTypeFunction() : null;
				visitType(ot ? ot.nextOf() : null); // the return type
			}
		}

		override void visit(AggregateDeclaration ad)
		{
			if (ad.isInterfaceDeclaration)
				addIdent(ad.loc, ad.ident, TypeReferenceKind.Interface);
			else if (ad.isClassDeclaration)
				addIdent(ad.loc, ad.ident, TypeReferenceKind.Class);
			else if (ad.isUnionDeclaration)
				addIdent(ad.loc, ad.ident, TypeReferenceKind.Union);
			else
				addIdent(ad.loc, ad.ident, TypeReferenceKind.Struct);
			super.visit(ad);
		}

		override void visit(AliasDeclaration ad)
		{
			// the alias identifier can be both before and after the aliased type,
			//  but we rely on so ascending locations in addTypePos
			// as a work around, add the declared identifier before and after
			//  by processing it twice
			super.visit(ad);
			super.visit(ad);
		}
	}

	scope IdentifierTypesVisitor itv = new IdentifierTypesVisitor;
	itv.filename = mod.srcfile.toChars();
	mod.accept(itv);

	return itv.idTypes;
}

////////////////////////////////////////////////////////////////////////////////
struct Reference
{
	Loc loc;
	Identifier ident;
}

Reference[] findReferencesInModule(Module mod, int line, int index)
{
	auto filename = mod.srcfile.toChars();
	scope FindDefinitionVisitor fdv = new FindDefinitionVisitor(filename, line, index, line, index + 1);
	mod.accept(fdv);

	if (!fdv.found)
		return null;

	extern(C++) class FindReferencesVisitor : ASTVisitor
	{
		RootObject search;
		Reference[] references;
		const(char)* filename;

		alias visit = ASTVisitor.visit;

		extern(D)
		void addReference(ref const Loc loc, Identifier ident)
		{
			if (loc.filename is filename && ident)
				if (!references.contains(Reference(loc, ident)))
					references ~= Reference(loc, ident);
		}

		void addResolved(ref const Loc loc, Expression resolved)
		{
			if (resolved)
				if (auto se = resolved.isScopeExp())
					if (se.sds is search)
						addReference(loc, se.sds.ident);
		}

		void addPackages(Module mod, IdentifiersAtLoc* packages)
		{
			if (!mod || !packages)
				return;

			Package pkg = mod.parent ? mod.parent.isPackage() : null;
			for (size_t p; pkg && p < packages.dim; p++)
			{
				size_t q = packages.dim - 1 - p;
				if (pkg is search)
					addReference((*packages)[q].loc, (*packages)[q].ident);
				if (auto parent = pkg.parent)
					pkg = parent.isPackage();
			}
		}

		override void visit(Dsymbol sym)
		{
			if (sym is search)
				addReference(sym.loc, sym.ident);
			super.visit(sym);
		}
		override void visit(Module mod)
		{
			if (mod.md)
			{
				addPackages(mod, mod.md.packages);
				if (mod is search)
					addReference(mod.md.loc, mod.md.id);
			}
			visit(cast(Package)mod);
		}

		override void visit(Import imp)
		{
			addPackages(imp.mod, imp.packages);

			if (imp.mod is search)
				addReference(imp.loc, imp.id);

			for (int n = 0; n < imp.names.dim; n++)
			{
				// names? (imp.names[n].loc, imp.names[n].ident)
				if (n < imp.aliasdecls.dim)
					if (imp.aliasdecls[n].aliassym is search)
						addReference(imp.names[n].loc, imp.names[n].ident);
			}
			// symbol has ident of first package, so don't forward
		}

		override void visit(SymbolExp expr)
		{
			if (expr.var is search)
				addReference(expr.loc, expr.var.ident);
			super.visit(expr);
		}
		override void visit(DotVarExp dve)
		{
			if (dve.var is search)
				addReference(dve.varloc.filename ? dve.varloc : dve.loc, dve.var.ident);
			super.visit(dve);
		}
		override void visit(TypeExp te)
		{
			if (auto ts = typeSymbol(te.type))
			    if (ts is search)
			        addReference(te.loc, ts.ident);
			super.visit(te);
		}

		override void visit(IdentifierExp expr)
		{
			addResolved(expr.loc, expr.resolvedTo);
			super.visit(expr);
		}

		override void visit(DotIdExp expr)
		{
			addResolved(expr.identloc, expr.resolvedTo);
			super.visit(expr);
		}

		override void visit(TypeQualified tid)
		{
			foreach (i, id; tid.idents)
			{
				RootObject obj = id;
				if (obj.dyncast() == DYNCAST.identifier)
				{
					auto ident = cast(Identifier)obj;
					if (tid.parentScopes.dim > i + 1)
						if (tid.parentScopes[i + 1] is search)
							addReference(id.loc, ident);
				}
			}
			super.visit(tid);
		}

		override void visit(TypeIdentifier tid)
		{
			while (tid.copiedFrom)
			{
				if (tid.parentScopes.dim > 0)
					break;
				tid = tid.copiedFrom;
			}
			if (tid.parentScopes.dim > 0)
				if (tid.parentScopes[0] is search)
					addReference(tid.loc, tid.ident);

			super.visit(tid);
		}

		override void visit(TypeInstance tid)
		{
			if (!tid.tempinst)
				return;
			if (tid.parentScopes.dim > 0)
				if (tid.parentScopes[0] is search)
					addReference(tid.loc, tid.tempinst.name);

			super.visit(tid);
		}
	}

	scope FindReferencesVisitor frv = new FindReferencesVisitor();

	if (auto t = fdv.found.isType())
	{
		if (t.ty == Tstruct)
			fdv.found = (cast(TypeStruct)t).sym;
	}
	else if (auto e = fdv.found.isExpression())
	{
		switch(e.op)
		{
			case TOK.variable:
			case TOK.symbolOffset:
				fdv.found = (cast(SymbolExp)e).var;
				break;
			case TOK.dotVariable:
				fdv.found = (cast(DotVarExp)e).var;
				break;
			default:
				break;
		}
	}
	frv.search = fdv.found;
	frv.filename = filename;
	mod.accept(frv);

	return frv.references;
}

////////////////////////////////////////////////////////////////////////////////
string symbol2ExpansionType(Dsymbol sym)
{
	if (sym.isInterfaceDeclaration())
		return "IFAC";
	if (sym.isClassDeclaration())
		return "CLSS";
	if (sym.isUnionDeclaration())
		return "UNIO";
	if (sym.isStructDeclaration())
		return "STRU";
	if (sym.isEnumDeclaration())
		return "ENUM";
	if (sym.isEnumMember())
		return "EVAL";
	if (sym.isAliasDeclaration())
		return "ALIA";
	if (sym.isTemplateDeclaration())
		return "TMPL";
	if (sym.isTemplateMixin())
		return "NMIX";
	if (sym.isModule())
		return "MOD";
	if (sym.isPackage())
		return "PKG";
	if (sym.isFuncDeclaration())
	{
		auto p = sym.toParent2;
		return p && p.isAggregateDeclaration ? "MTHD" : "FUNC";
	}
	if (sym.isVarDeclaration())
	{
		auto p = sym.toParent2;
		return p && p.isAggregateDeclaration ? "PROP" : "VAR"; // "SPRP"?
	}
	if (sym.isOverloadSet())
		return "OVR";
	return "TEXT";
}

string symbol2ExpansionLine(Dsymbol sym)
{
	string type = symbol2ExpansionType(sym);
	string tip = tipForObject(sym);
	return type ~ ":" ~ tip.replace("\n", "\a");
}

////////////////////////////////////////////////////////////////

extern(C++) class FindExpansionsVisitor : FindASTVisitor
{
	alias visit = FindASTVisitor.visit;

	this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
	{
		super(filename, startLine, startIndex, endLine, endIndex);
	}
}

string[] findExpansions(Module mod, int line, int index, string tok)
{
	auto filename = mod.srcfile.toChars();
	scope FindExpansionsVisitor fdv = new FindExpansionsVisitor(filename, line, index, line, index + 1);
	mod.accept(fdv);

	if (!fdv.found)
		return null;

	int flags = 0;
	Type type = fdv.found.isType();
	if (auto e = fdv.found.isExpression())
	{
		Type getType(Expression e, bool recursed)
		{
			switch(e.op)
			{
				case TOK.variable:
				case TOK.symbolOffset:
					if(recursed)
						return (cast(SymbolExp)e).var.type;
					return null;

				case TOK.dotVariable:
				case TOK.dotIdentifier:
					flags |= SearchLocalsOnly;
					return getType((cast(UnaExp)e).e1, true);

				case TOK.dot:
					flags |= SearchLocalsOnly;
					return (cast(DotExp)e).e1.type;
				default:
					return recursed ? e.type : null;
			}
		}
		if (auto t = getType(e, false))
			type = t;
	}

	auto sds = fdv.foundScope;
	if (type)
		if (auto sym = typeSymbol(type))
			sds = sym;

	string[void*] idmap; // doesn't work with extern(C++) classes

	void searchScope(ScopeDsymbol sds, int flags)
	{
		static Dsymbol uplevel(Dsymbol s)
		{
			if (auto ad = s.isAggregateDeclaration())
				return ad.enclosing;
			return s.toParent;
		}
		// TODO: properties
		// TODO: struct/class not going to parent if accessed from elsewhere (but does if nested)

		for (Dsymbol ds = sds; ds; ds = uplevel(ds))
		{
			ScopeDsymbol sd = ds.isScopeDsymbol();
			if (!sd)
				continue;

			//foreach (pair; sd.symtab.tab.asRange)
			if (sd.symtab)
			{
				foreach (kv; sd.symtab.tab.asRange)
				{
					//Dsymbol s = pair.value;
					if (!symbolIsVisible(mod, kv.value))
						continue;
					auto ident = /*pair.*/(cast(Identifier)kv.key).toString();
					if (ident.startsWith(tok))
						idmap[cast(void*)kv.value] = ident.idup;
				}
			}

			// base classes
			if (auto cd = ds.isClassDeclaration())
			{
				if (auto bcs = cd.baseclasses)
					foreach (bc; *bcs)
					{
						int sflags = 0;
						if (bc.sym.getModule() == mod)
							sflags |= IgnoreSymbolVisibility;
						searchScope(bc.sym, sflags);
					}
			}

			// TODO: alias this

			// imported modules
			size_t cnt = sd.importedScopes ? sd.importedScopes.dim : 0;
			for (size_t i = 0; i < cnt; i++)
			{
				if ((flags & IgnorePrivateImports) && sd.prots[i] == Prot.Kind.private_)
					continue;
				auto ss = (*sd.importedScopes)[i].isScopeDsymbol();
				if (!ss)
					continue;

				int sflags = 0;
				if (ss.isModule())
				{
					if (flags & SearchLocalsOnly)
						continue;
					sflags |= IgnorePrivateImports;
				}
				else // mixin template
				{
					if (flags & SearchImportsOnly)
						continue;
					sflags |= SearchLocalsOnly;
				}
				searchScope(ss, sflags | IgnorePrivateImports);
			}
		}
	}
	searchScope(sds, flags);

	string[] idlist;
	foreach(sym, id; idmap)
		idlist ~= id ~ ":" ~ symbol2ExpansionLine(cast(Dsymbol)sym);
	return idlist;
}

////////////////////////////////////////////////////////////////////////////////

bool isConstantExpr(Expression expr)
{
	switch(expr.op)
	{
		case TOK.int64, TOK.float64, TOK.char_, TOK.complex80:
		case TOK.null_, TOK.void_:
		case TOK.string_:
		case TOK.arrayLiteral, TOK.assocArrayLiteral, TOK.structLiteral:
		case TOK.classReference:
			//case TOK.type:
		case TOK.vector:
		case TOK.function_, TOK.delegate_:
		case TOK.symbolOffset, TOK.address:
		case TOK.typeid_:
		case TOK.slice:
			return true;
		default:
			return false;
	}
}

// return first argument to aaLen()
Expression isAALenCall(Expression expr)
{
	// unpack first argument of _aaLen(aa)
	if (auto ce = expr.isCallExp())
		if (auto ve = ce.e1.isVarExp())
			if (ve.var.ident is Id.aaLen)
				if (ce.arguments && ce.arguments.dim > 0)
					return (*ce.arguments)[0];
	return null;
}

////////////////////////////////////////////////////////////////////////////////

ScopeDsymbol typeSymbol(Type type)
{
	if (auto ts = type.isTypeStruct())
		return ts.sym;
	if (auto tc = type.isTypeClass())
		return tc.sym;
	if (auto te = type.isTypeEnum())
		return te.sym;
	return null;
}

Module cloneModule(Module mo)
{
	if (!mo)
		return null;
	Module m = new Module(mo.srcfile.toString(), mo.ident, mo.isDocFile, mo.isHdrFile);
	*cast(FileName*)&(m.srcfile) = mo.srcfile; // keep identical source file name pointer
	m.isPackageFile = mo.isPackageFile;
	m.md = mo.md;
	mo.syntaxCopy(m);

	extern(C++) class AdjustModuleVisitor : ASTVisitor
	{
		// avoid allocating capture
		Module m;
		this (Module m)
		{
			this.m = m;
			unconditional = true;
		}

		alias visit = ASTVisitor.visit;

		override void visit(ConditionalStatement cond)
		{
			if (auto dbg = cond.condition.isDebugCondition())
				cond.condition = new DebugCondition(dbg.loc, m, dbg.level, dbg.ident);
			else if (auto ver = cond.condition.isVersionCondition())
				cond.condition = new VersionCondition(ver.loc, m, ver.level, ver.ident);
			super.visit(cond);
		}

		override void visit(ConditionalDeclaration cond)
		{
			if (auto dbg = cond.condition.isDebugCondition())
				cond.condition = new DebugCondition(dbg.loc, m, dbg.level, dbg.ident);
			else if (auto ver = cond.condition.isVersionCondition())
				cond.condition = new VersionCondition(ver.loc, m, ver.level, ver.ident);
			super.visit(cond);
		}
	}

	import dmd.permissivevisitor;
	scope v = new AdjustModuleVisitor(m);
	m.accept(v);
	return m;
}

Module createModuleFromText(string filename, string text)
{
	import std.path;

	text ~= "\0\0"; // parser needs 2 trailing zeroes
	string name = stripExtension(baseName(filename));
	auto id = Identifier.idPool(name);
	auto mod = new Module(filename, id, true, false);
	mod.srcBuffer = new FileBuffer(cast(ubyte[])text);
	mod.read(Loc.initial);
	mod.parse();
	return mod;
}

////////////////////////////////////////////////////////////////////////////////

