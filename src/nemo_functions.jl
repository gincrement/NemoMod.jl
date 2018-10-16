#=
    NEMO: Next-generation Energy Modeling system for Optimization.
    https://github.com/sei-international/NemoMod.jl

    Copyright © 2018: Stockholm Environment Institute U.S.

    Release 0.1: Julia version of OSeMOSYS version 2017_11_08.  http://www.osemosys.org/

    File description: Main function library for NEMO.
=#

"""Prints a log message (msg) to STDOUT."""
function logmsg(msg::String, dtm=now()::DateTime)
    println(stdout, Dates.format(dtm, @dateformat_str "YYYY-dd-u HH:MM:SS.sss ") * msg)
end  # logmsg(msg::String)

"""Translates an OSeMOSYS set abbreviation (a) into the set's name."""
function translatesetabb(a::String)
    if a == "y"
        return "YEAR"
    elseif a == "t"
        return "TECHNOLOGY"
    elseif a == "f"
        return "FUEL"
    elseif a == "e"
        return "EMISSION"
    elseif a == "m"
        return "MODE_OF_OPERATION"
    elseif a == "r" || a == "rr"
        return "REGION"
    elseif a == "ls"
        return "SEASON"
    elseif a == "ld"
        return "DAYTYPE"
    elseif a == "lh"
        return "DAILYTIMEBRACKET"
    elseif a == "s"
        return "STORAGE"
    elseif a == "l"
        return "TIMESLICE"
    else
        return a
    end
end  # translatesetabb(a::String)

"""For each OSeMOSYS parameter table identified in tables, creates a view that explicitly shows the default value for the val
column, if one is available. View name = [table name]  * "_def"."""
function createviewwithdefaults(db::SQLite.DB, tables::Array{String,1})
    for t in tables
        local hasdefault::Bool = false  # Indicates whether val column in t has a default value
        local defaultval  # Default value for val column in t, if column has a default value
        local pks::Array{String,1} = Array{String,1}()  # Names of foreign key fields in t
        local createviewstmt::String  # Create view SQL statement that will be executed for t

        # Delete view if existing already
        if length(SQLite.query(db, "PRAGMA table_info('" * t * "_def')")) > 0
            SQLite.query(db,"drop view " * t * "_def")
        end

        # BEGIN: Extract foreign key fields and default value from t.
        for row in eachrow(SQLite.query(db, "PRAGMA table_info('" * t *"')"))
            local rowname::String = row[:name]  # Value in name field for row

            if rowname == "id"
                continue
            elseif rowname == "val"
                if !ismissing(row[:dflt_value])
                    defaultval = row[:dflt_value]

                    # Some special handling here to avoid creating large views where they're not necessary, given OSeMOSYS's logic
                    if (t == "OutputActivityRatio" || t == "InputActivityRatio") && defaultval == "0"
                        # OutputActivityRatio and InputActivityRatio are only used when != 0, so can ignore a default value of 0
                        hasdefault = false
                    else
                        hasdefault = true
                    end
                end
            else
                push!(pks,rowname)
            end
        end
        # END: Extract foreign key fields and default value from t.

        # BEGIN: Create unique index on t for foreign key fields.
        # This step significantly improves performance for many queries on new view for t
        SQLite.query(db,"drop index if exists " * t * "_fks_unique")
        SQLite.query(db,"create unique index " * t * "_fks_unique on " * t * " (" * join(pks, ",") * ")")
        # END: Create unique index on t for foreign key fields.

        if hasdefault
            # Join to primary key tables with default specified
            local outerfieldsclause::String = ""  # Dynamic fields clause for create view outer select
            local innerfieldsclause::String = ""  # Dynamic fields clause for create view inner select
            local fromclause::String = ""  # Dynamic from clause for create view inner select
            local leftjoinclause::String = ""  # Dynamic left join criteria for create view inner select

            for f in pks
                outerfieldsclause = outerfieldsclause * f * ", "
                innerfieldsclause = innerfieldsclause * f * "_tab.val as " * f * ", "
                fromclause = fromclause * translatesetabb(f) * " as " * f * "_tab, "
                leftjoinclause = leftjoinclause * "t." * f * " = " * f * "_tab.val and "
            end

            innerfieldsclause = innerfieldsclause * "t.val as val "
            fromclause = fromclause[1:end-2] * " "
            leftjoinclause = leftjoinclause[1:end-4]

            createviewstmt = "create view " * t * "_def as select " * outerfieldsclause * "ifnull(val," * string(defaultval) * ") as val from (select " * innerfieldsclause * "from " * fromclause * "left join " * t * " t on " * leftjoinclause * ")"
        else
            # No default value, so view with defaults is a simple copy of t
            createviewstmt = "create view " * t * "_def as select * from " * t
        end

        # println("createviewstmt = " * createviewstmt)
        SQLite.query(db, createviewstmt)
    end
end  # createviewwithdefaults(tables::Array{String,1})

"""Generates Dicts that can be used to restrict JuMP constraints or variables to selected indices
(rather than all values in their dimensions) at creation. Requires two arguments:
    1) df - The results of a query that selects the index values.
    2) numdicts - The number of Dicts that should be created.  The first Dict is for the first field in
        the query, the second is for the first two fields in the query, and so on.  Dict keys are arrays
        of the values of the key fields to which the Dict corresponds, and Dict values are Sets of corresponding
        values in the next field of the query (field #2 for the first Dict, field #3 for the second Dict, and so on).
Returns an array of the generated Dicts."""
function keydicts(df::DataFrames.DataFrame, numdicts::Int)
    local returnval = Array{Dict{Array{String,1},Set{String}},1}()  # Function return value

    # Set up empty dictionaries in returnval
    for i in 1:numdicts
        push!(returnval, Dict{Array{String,1},Set{String}}())
    end

    # Populate dictionaries using df
    for row in eachrow(df)
        for j in 1:numdicts
            if !haskey(returnval[j], [row[k] for k = 1:j])
                returnval[j][[row[k] for k = 1:j]] = Set{String}()
            end

            push!(returnval[j][[row[k] for k = 1:j]], row[j+1])
        end
    end

    return returnval
end  # keydicts(df::DataFrames.DataFrame, numdicts::Int)

"""Runs keydicts using parallel processes identified in targetprocs. If there are not at least 10,000 rows in df for each
target process, resorts to running keydicts on process that called keydicts_parallel."""
function keydicts_parallel(df::DataFrames.DataFrame, numdicts::Int, targetprocs::Array{Int,1})
    local returnval = Array{Dict{Array{String,1},Set{String}},1}()  # Function return value
    local availprocs::Array{Int, 1} = intersect(procs(), targetprocs)  # Targeted processes that actually exist
    local np::Int = length(availprocs)  # Number of targeted processes that actually exist
    local dfrows::Int = size(df)[1]  # Number of rows in df

    if np <= 1 || div(dfrows, np) < 10000
        # Run keydicts for entire df
        returnval = keydicts(df, numdicts)
    else
        # Divide operation among available processes
        local blockdivrem = divrem(dfrows, np)  # Quotient and remainder from dividing dfrows by np; element 1 = quotient, element 2 = remainder
        local results = Array{typeof(returnval), 1}(np)  # Collection of results from async processing

        # Dispatch async tasks in main process, each of which performs a remotecall_fetch on an available process. Wrap in sync block to wait until all async processes
        #   finish before proceeding.
        @sync begin
            for p=1:np
                @async begin
                    # Pass each process a block of rows from df
                    results[p] = remotecall_fetch(keydicts, availprocs[p], df[((p-1) * blockdivrem[1] + 1):((p) * blockdivrem[1] + (p == np ? blockdivrem[2] : 0)),:], numdicts)
                end
            end
        end

        # Merge results from async tasks
        for i = 1:numdicts
            push!(returnval, Dict{Array{String,1},Set{String}}())

            for j = 1:np
                returnval[i] = merge(union, returnval[i], results[j][i])
            end
        end
    end

    return returnval
end  # keydicts_parallel(df::DataFrames.DataFrame, numdicts::Int, targetprocs::Array{Int,1})

#= Testing code:
using JuMP, SQLite, IterTools, NullableArrays, DataFrames
dbpath = "C:\\temp\\utopia_2015_08_27.sl3"
db = SQLite.DB(dbpath)
stechnology = dropnull(SQLite.query(db, "select val from technology limit 10")[:val])
@constraintref(abc[1:10])
m = Model()
@variable(m, vtest[stechnology])
createconstraint(m, "TestConstraint", abc, eachrow(SQLite.query(db, "select t.val as t from technology t limit 10")), ["t"], "vtest[t]", ">=", "0")
=#

# Demonstration function - performance is too poor for production use
function createconstraint(model::JuMP.Model, logname::String, constraintref::Array{JuMP.ConstraintRef,1}, rows::DataFrames.DFRowIterator,
    keyfields::Array{String,1}, lh::String, operator::String, rh::String)

    local constraintnum = 1  # Number of next constraint to be added to constraint array
    global row = Void  # Row in subsequent iteration; needs to be defined as global to be accessible in eval statements

    for rw in rows
        row = rw

        for kf in keyfields
            eval(parse(kf * " = row[:" * kf * "]"))
        end

        if operator == "=="
            constraintref[constraintnum] = @constraint(model, eval(parse(lh)) == eval(parse(rh)))
        elseif operator == "<="
            constraintref[constraintnum] = @constraint(model, eval(parse(lh)) <= eval(parse(rh)))
        elseif operator == ">="
            constraintref[constraintnum] = @constraint(model, eval(parse(lh)) >= eval(parse(rh)))
        end

        constraintnum += 1
    end

    logmsg("Created constraint " * logname * ".")
end  # createconstraint

"""Returns an array of model variables corresponding to the names in varnames. Excludes any variables not convertible to
    JuMP.JuMPContainer."""
function getvars(varnames::Array{String, 1})
    local returnval::Array{JuMP.JuMPContainer, 1} = Array{JuMP.JuMPContainer, 1}()  # Function's return value

    for v in varnames
        try
            push!(returnval, Core.eval(@__MODULE__, Symbol(v)))
        catch ex
            throw(ex)
        end
    end

    return returnval
end  # getvars(varnames::Array{String, 1})

"""Saves model results to a SQLite database using SQL inserts with transaction batching. Requires three arguments:
    1) vars - Names of model variables for which results will be retrieved and saved to database.
    2) modelvarindices - Dictionary mapping model variable names to tuples of (variable, [index column names]).
    3) db - SQLite database.
    4) solvedtmstr - String to write into solvedtm field in result tables."""
function savevarresults(vars::Array{String,1}, modelvarindices::Dict{String, Tuple{JuMP.JuMPContainer,Array{String,1}}}, db::SQLite.DB, solvedtmstr::String)
    for vname in intersect(vars, keys(modelvarindices))
        local v = modelvarindices[vname][1]  # Model variable corresponding to vname
        local gvv = JuMP.getvalue(v)  # Value of v in model solution
        local indices::Array{Tuple}  # Array of tuples of index values for v
        local vals::Array{Float64}  # Array of model results for v

        # Populate indices and vals
        if v isa JuMP.JuMPArray
            indices = collect(Base.product(gvv.indexsets...))  # Ellipsis splices indexsets into its values for passing to product()
            vals = gvv.innerArray
        elseif v isa JuMP.JuMPDict
            indices = collect(keys(gvv.tupledict))
            vals = collect(values(gvv.tupledict))
        end

        # BEGIN: Wrap database operations in try-catch block to allow rollback on error.
        try
            # Begin SQLite transaction
            SQLite.execute!(db, "BEGIN")

            # Create target table for v (drop any existing table for v)
            SQLite.query(db,"drop table if exists " * vname)

            SQLite.execute!(db, "create table '" * vname * "' ('" * join(modelvarindices[vname][2], "' text, '") * "' text, 'val' real, 'solvedtm' text)")

            # Insert data from gvv
            for i = 1:length(vals)
                SQLite.execute!(db, "insert into " * vname * " values('" * join(indices[i], "', '") * "', '" * string(vals[i]) * "', '" * solvedtmstr * "')")
            end

            # Complete SQLite transaction
            SQLite.execute!(db, "COMMIT")
            logmsg("Saved results for " * vname * " to database.")
        catch
            # Rollback db transaction
            SQLite.execute!(db, "ROLLBACK")

            # Proceed with normal Julia error sequence
            rethrow()
        end
        # END: Wrap database operations in try-catch block to allow rollback on error.
    end
end  # savevarresults(vars::Array{String,1}, modelvarindices::Dict{String, Tuple{JuMP.JuMPContainer,Array{String,1}}}, db::SQLite.DB, solvedtmstr::String)

"""Drops all tables in db whose name begins with "v" or "sqlite_stat" (both case-sensitive)."""
function dropresulttables(db::SQLite.DB)
    for row in eachrow(SQLite.tables(db))
        local name = row[:name]

        if name[1:1] == "v" || (length(name) >= 11 && name[1:11] == "sqlite_stat")
            SQLite.execute!(db, "drop table " * name)
            logmsg("Dropped table " * name * ".")
        end
    end
end  # dropresulttables(db::SQLite.DB)

"""Returns the absolute path of the directory for the NemoMod package (specifically, one level above the directory
    containing the file in which this function is declared)."""
function packagedirectory()
    return normpath(joinpath(@__DIR__, ".."))
end  # packagedirectory()

"""This function is deprecated."""
function startnemo(dbpath::String, solver::String = "Cbc", numprocs::Int = Sys.CPU_THREADS)
    # Note: Sys.CPU_THREADS was Sys.CPU_CORES in Julia 0.6

    # Sample paths
    # dbpath = "C:\\temp\\TEMBA_datafile.sl3"
    # dbpath = "C:\\temp\\TEMBA_datafile_2010_only.sl3"
    # dbpath = "C:\\temp\\SAMBA_datafile.sl3"
    # dbpath = "C:\\temp\\utopia_2015_08_27.sl3"

    # BEGIN: Parameter validation.
    if !ispath(dbpath)
        error("dbpath must refer to a valid file system path.")
    end

    if uppercase(solver) == "CPLEX"
        solver = "CPLEX"
    elseif uppercase(solver) == "CBC"
        solver = "Cbc"
    else
        error("Requested solver (" * solver * ") is not supported.")
    end

    if numprocs < 1
        error("numprocs must be >= 1.")
    end
    # END: Parameter validation.

    # BEGIN: Add worker processes.
    while nprocs() < numprocs
        addprocs(1)
    end
    # END: Add worker processes.

    # BEGIN: Call main function for NEMO.
    @everywhere include(joinpath(Pkg.dir(), "NemoMod\\src\\NemoMod.jl"))  # Note that @everywhere loads file in Main module on all processes

    @time NemoMod.nemomain(dbpath, solver)
    # END: Call main function for NEMO.
end  # startnemo(dbpath::String, solver::String = "Cbc", numprocs::Int = Sys.CPU_CORES)
