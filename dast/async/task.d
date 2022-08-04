module dast.async.task;

// dfmt off
import core.atomic,
	dast.async.container,
	std.exception,
	std.experimental.allocator,
	std.traits,
	std.variant;
// dfmt on

ReturnType!F run(F, Args...)(F fpOrDelegate, ref Args args) {
	return fpOrDelegate(args);
}

enum TaskStatus : ubyte {
	LDLE,
	Runing,
	Finsh,
	InVaild,
}

@trusted class TaskBase {
	alias TaskFun = bool function(TaskBase);
	alias FinishCall = void delegate(TaskBase) nothrow;

	final void job() nothrow {
		if (atomicLoad(_status) != TaskStatus.LDLE)
			return;
		atomicStore(_status, TaskStatus.Runing);
		scope (failure)
			atomicStore(_status, TaskStatus.InVaild);
		bool rv;
		if (_runTask)
			_e = collectException(_runTask(this), rv);
		atomicStore(_status, rv ? TaskStatus.Finsh : TaskStatus.InVaild);
		if (_finish)
			_finish(this);
	}

	final rest() {
		if (isRuning)
			return false;
		atomicStore(_status, TaskStatus.LDLE);
		return true;
	}

	@property final status() {
		return atomicLoad(_status);
	}

	pragma(inline, true) final bool isRuning() {
		return atomicLoad(_status) == TaskStatus.Runing;
	}

	@property @safe {
		Variant returnValue() @trusted {
			return _rvalue;
		}

		Exception throwExecption() {
			return _e;
		}

		FinishCall finishedCall() {
			return _finish;
		}

		void finishedCall(FinishCall finish) {
			_finish = finish;
		}
	}

protected:
	this(TaskFun fun) {
		_runTask = fun;
	}

private:
	TaskFun _runTask;
	shared TaskStatus _status = TaskStatus.LDLE;
	//return
	Exception _e;
	Variant _rvalue;
	FinishCall _finish;
	// Use in queue
	package TaskBase next;
}

@trusted final class Task(alias fun, Args...) : TaskBase {
	static if (Args.length > 0) {
		this(Args args) {
			_args = args;
			super(&impl);
		}

		Args _args;
	} else {
		this() {
			super(&impl);
		}

		alias _args = void;
	}

	static bool impl(TaskBase myTask) {
		auto myCastedTask = cast(typeof(this))myTask;
		if (myCastedTask is null)
			return false;
		alias RType = typeof(fun(_args));
		static if (is(RType == void))
			fun(myCastedTask._args);
		else
			myCastedTask._rvalue = fun(myCastedTask._args);
		return true;
	}
}

///Note:from GC
@trusted auto newTask(alias fun, Args...)(Args args) {
	return new Task!(fun, Args)(args);
}

///Note:from GC
@trusted auto newTask(F, Args...)(F delegateOrFp, Args args)
if (is(typeof(delegateOrFp(args)))) {
	return new Task!(run, F, Args)(delegateOrFp, args);
}

alias TaskQueue = Queue!(TaskBase, true);

unittest {
	int tfun() {
		return 10;
	}

	TaskBase test = newTask(&tfun);
	test.finishedCall = (TaskBase task) nothrow @trusted {
		try {
			import std.stdio;

			int a = task.returnValue.get!int;
			assert(task.status == TaskStatus.Finsh);
			assert(a == 10);
			writeln("-------------task call finish!!");
		} catch (Exception e)
			writeln(e);
	};
	assert(test.status == TaskStatus.LDLE);
	test.job();
	int a = test.returnValue.get!int;
	assert(test.status == TaskStatus.Finsh);
	assert(a == 10);
}
