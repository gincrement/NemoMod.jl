#=
    NEMO: Next-generation Energy Modeling system for Optimization.
    https://github.com/sei-international/NemoMod.jl

    Copyright © 2018: Stockholm Environment Institute U.S.

    File description: Functions for calculating a NEMO scenario.
=#

"""
    calculatescenario(dbpath; jumpmodel = Model(solver = GLPKSolverMIP(presolve=true)),
    varstosave = "vdemandnn, vnewcapacity, vtotalcapacityannual,
        vproductionbytechnologyannual, vproductionnn, vusebytechnologyannual,
        vusenn, vtotaldiscountedcost",
    numprocs::Int = 0, targetprocs = Array{Int, 1}(), restrictvars = true,
    reportzeros = false, continuoustransmission = false, quiet = false)

Calculates a scenario specified in a scenario database. Returns a `Symbol` indicating
the solve status reported by the solver (e.g., `:Optimal`).

# Arguments
- `dbpath::String`: Path to the scenario database (must be a SQLite version 3 database).
- `jumpmodel::JuMP.Model`: [JuMP](https://github.com/JuliaOpt/JuMP.jl) model object
    specifying the MIP solver to be used.
    Examples: `Model(solver = GLPKSolverMIP(presolve=true))`, `Model(solver = CplexSolver())`,
    `Model(solver = CbcSolver(logLevel=1, presolve="on"))`.
    Note that the solver's Julia package (Julia wrapper) must be installed. See the
    documentation for solver Julia packages for information on how to configure solver
    options.
- `varstosave::String`: Comma-delimited list of output variables whose results should be
    saved in the scenario database.
- `numprocs::Int`: Number of Julia processes to use for parallelized operations within the
    scenario calculation. Ignored if `targetprocs` is specified. Should be a positive integer
    or 0 for half the number of logical processors on the executing machine (i.e., half
    of `Sys.CPU_THREADS`). When `numprocs` is in effect, NEMO selects processes for parallel
    operations from `Distributed.procs()`. Processes are taken in the order they appear in
    this array. If there are not enough processes defined in `Distributed.procs()`, NEMO adds
    processes on the local host as needed.
- `targetprocs::Array{Int, 1}`: Identifiers of Julia processes that should be used for
    parallelized operations within the scenario calculation.
- `restrictvars::Bool`: Indicates whether NEMO should conduct additional data analysis
    to limit the set of model variables created for the scenario. By default, to improve
    performance, NEMO selectively creates certain variables to avoid combinations of
    subscripts that do not exist in the scenario's data. This option increases the
    stringency of this filtering. It requires more processing time as the model is
    built, but it can substantially reduce the solve time for large models.
- `reportzeros::Bool`: Indicates whether results saved in the scenario database should
    include values equal to zero. Specifying `false` can substantially improve the
    performance of large models.
- `continuoustransmission::Bool`: Indicates whether continuous (true) or binary (false)
    variables are used to represent investment decisions for candidate transmission lines. Not
    relevant in scenarios that do not model transmission.
- `quiet::Bool`: Suppresses low-priority status messages (which are otherwise printed to
    `STDOUT`).
"""
function calculatescenario(
    dbpath::String;
    jumpmodel::JuMP.Model = Model(solver = GLPKSolverMIP(presolve=true)),
    varstosave::String = "vdemandnn, vnewcapacity, vtotalcapacityannual, vproductionbytechnologyannual, vproductionnn, vusebytechnologyannual, vusenn, vtotaldiscountedcost",
    numprocs::Int = 0,
    targetprocs::Array{Int, 1} = Array{Int, 1}(),
    restrictvars::Bool = true,
    reportzeros::Bool = false,
    continuoustransmission::Bool = false,
    quiet::Bool = false)

    try
        calculatescenario_main(dbpath; jumpmodel=jumpmodel, varstosave=varstosave, numprocs=numprocs, targetprocs=targetprocs,
            restrictvars=restrictvars, reportzeros=reportzeros, continuoustransmission=continuoustransmission, quiet=quiet)
    catch e
        println("NEMO encountered an error with the following message: " * sprint(showerror, e) * ".")
        println("To report this issue to the NEMO team, please submit an error report at https://leap.sei.org/support/. Please include in the report a list of steps to reproduce the error and the error message. Press Enter to continue.")
    end
end  # calculatescenario()

"""
    calculatescenario_main(dbpath; jumpmodel = Model(solver = GLPKSolverMIP(presolve=true)),
    varstosave = "vdemandnn, vnewcapacity, vtotalcapacityannual,
        vproductionbytechnologyannual, vproductionnn, vusebytechnologyannual,
        vusenn, vtotaldiscountedcost",
    numprocs::Int = 0, targetprocs = Array{Int, 1}(), restrictvars = true,
    reportzeros = false, continuoustransmission = false, quiet = false)

Implements main scenario calculation logic for calculatescenario().
"""
function calculatescenario_main(
    dbpath::String;
    jumpmodel::JuMP.Model = Model(solver = GLPKSolverMIP(presolve=true)),
    varstosave::String = "vdemandnn, vnewcapacity, vtotalcapacityannual, vproductionbytechnologyannual, vproductionnn, vusebytechnologyannual, vusenn, vtotaldiscountedcost",
    numprocs::Int = 0,
    targetprocs::Array{Int, 1} = Array{Int, 1}(),
    restrictvars::Bool = true,
    reportzeros::Bool = false,
    continuoustransmission::Bool = false,
    quiet::Bool = false)
# Lines within calculatescenario_main() are not indented since the function is so lengthy. To make an otherwise local
# variable visible outside the function, prefix it with global. For JuMP constraint references,
# create a new global variable and assign to it the constraint reference.

logmsg("Started scenario calculation.")

# BEGIN: Validate arguments.
if !isfile(dbpath)
    error("dbpath argument must refer to a file.")
end

# Convert varstosave into an array of strings with no empty values
local varstosavearr = String.(split(replace(varstosave, " " => ""), ","; keepempty = false))

logmsg("Validated run-time arguments.", quiet)
# END: Validate arguments.

# BEGIN: Read config file and process calculatescenarioargs.
configfile = getconfig(quiet)  # ConfParse structure for config file if one is found; otherwise nothing

if configfile != nothing
    # Arrays of Boolean and Int arguments for calculatescenario(); necessary in order to have mutable objects for getconfigargs! call
    local boolargs::Array{Bool,1} = [restrictvars,reportzeros,continuoustransmission,quiet]
    local intargs::Array{Int,1} = [numprocs]

    getconfigargs!(configfile, varstosavearr, targetprocs, boolargs, intargs, quiet)

    numprocs = intargs[1]
    restrictvars = boolargs[1]
    reportzeros = boolargs[2]
    continuoustransmission = boolargs[3]
    quiet = boolargs[4]
end
# END: Read config file and process calculatescenarioargs.

# BEGIN: Set final value for targetprocs.
if length(targetprocs) == 0
    # Handle auto option for numprocs
    if numprocs == 0
        numprocs = max(div(Sys.CPU_THREADS, 2), 1)
        logmsg("0 specified for numprocs argument. Using " * string(numprocs) * " processes for parallelized operations.", quiet)
    end

    if numprocs < 0
        numprocs = 1
    end

    # Use first numprocs processes in procs(), adding processes as needed
    numprocs > nprocs() && addprocs(numprocs - nprocs())
    targetprocs = procs()[1:numprocs]
else
    # Use valid values in targetprocs (i.e., references to processes that are defined); if no valid values, revert to process 1
    targetprocs = intersect(procs(), targetprocs)

    if length(targetprocs) == 0
        targetprocs = [1]
    end
end
# END: Set final value for targetprocs.

# BEGIN: Load NemoMod on parallel processes.
if targetprocs != [1]
    # Load synchronously to avoid race conditions in precompilation
    for p in targetprocs
        if p != 1 && !remotecall_fetch(isdefined, p, Main, :NemoMod)
            remotecall_fetch(Core.eval, p, Main, :(using NemoMod))
        end
    end

    logmsg("Loaded NEMO on parallel processes " * join(targetprocs, ", ") * ".", quiet)
end
# END: Load NemoMod on parallel processes.

# BEGIN: Set module global variables that depend on arguments.
global csdbpath = dbpath
global csquiet = quiet
#global csjumpmodel = jumpmodel

if configfile != nothing && haskey(configfile, "includes", "customconstraints")
    # Define global variable for jumpmodel
    global csjumpmodel = jumpmodel
end
# END: Set module global variables that depend on arguments.

# BEGIN: Connect to SQLite database.
db = SQLite.DB(dbpath)
logmsg("Connected to scenario database. Path = " * dbpath * ".", quiet)
# END: Connect to SQLite database.

# BEGIN: Update database if necessary.
dbversion::Int64 = DataFrame(SQLite.DBInterface.execute(db, "select version from version"))[1, :version]

dbversion == 2 && db_v2_to_v3(db; quiet = quiet)
dbversion < 4 && db_v3_to_v4(db; quiet = quiet)
dbversion < 5 && db_v4_to_v5(db; quiet = quiet)
# END: Update database if necessary.

# BEGIN: Perform beforescenariocalc include.
if configfile != nothing && haskey(configfile, "includes", "beforescenariocalc")
    try
        include(normpath(joinpath(pwd(), retrieve(configfile, "includes", "beforescenariocalc"))))
        logmsg("Performed beforescenariocalc include.", quiet)
    catch e
        logmsg("Could not perform beforescenariocalc include. Error message: " * sprint(showerror, e) * ". Continuing with NEMO.", quiet)
    end
end
# END: Perform beforescenariocalc include.

# BEGIN: Drop any pre-existing result tables.
dropresulttables(db, true)
logmsg("Dropped pre-existing result tables from database.", quiet)
# END: Drop any pre-existing result tables.

# BEGIN: Check if transmission modeling is required.
local transmissionmodeling::Bool = false  # Indicates whether scenario involves transmission modeling
local tempquery::SQLite.Query = SQLite.DBInterface.execute(db, "select distinct type from TransmissionModelingEnabled")  # Temporary SQLite.Query object
local transmissionmodelingtypes::Array{Int64, 1} = SQLite.done(tempquery) ? Array{Int64, 1}() : collect(skipmissing(DataFrame(tempquery)[!, :type]))
    # Array of transmission modeling types requested for scenario

if length(transmissionmodelingtypes) > 0
    transmissionmodeling = true
end

# Temporary - save transmission variables if transmission modeling is enabled
transmissionmodeling && push!(varstosavearr, "vtransmissionbuilt", "vtransmissionexists", "vtransmissionbyline",
    "vtransmissionannual")

logmsg("Verified that transmission modeling " * (transmissionmodeling ? "is" : "is not") * " enabled.", quiet)
# END: Check if transmission modeling is required.

# BEGIN: Create parameter views showing default values and parameter indices.
# Array of parameter tables needing default views in scenario database
local paramsneedingdefs::Array{String, 1} = ["OutputActivityRatio", "InputActivityRatio", "ResidualCapacity", "OperationalLife",
"FixedCost", "YearSplit", "SpecifiedAnnualDemand", "SpecifiedDemandProfile", "VariableCost", "DiscountRate", "CapitalCost",
"CapitalCostStorage", "CapacityFactor", "CapacityToActivityUnit", "CapacityOfOneTechnologyUnit", "AvailabilityFactor",
"TradeRoute", "TechnologyToStorage", "TechnologyFromStorage", "StorageLevelStart", "StorageMaxChargeRate", "StorageMaxDischargeRate",
"ResidualStorageCapacity", "MinStorageCharge", "OperationalLifeStorage", "DepreciationMethod", "TotalAnnualMaxCapacity",
"TotalAnnualMinCapacity", "TotalAnnualMaxCapacityInvestment", "TotalAnnualMinCapacityInvestment",
"TotalTechnologyAnnualActivityUpperLimit", "TotalTechnologyAnnualActivityLowerLimit", "TotalTechnologyModelPeriodActivityUpperLimit",
"TotalTechnologyModelPeriodActivityLowerLimit", "ReserveMarginTagTechnology", "ReserveMarginTagFuel", "ReserveMargin", "RETagTechnology", "RETagFuel",
"REMinProductionTarget", "EmissionActivityRatio", "EmissionsPenalty", "ModelPeriodExogenousEmission",
"AnnualExogenousEmission", "AnnualEmissionLimit", "ModelPeriodEmissionLimit", "AccumulatedAnnualDemand", "TotalAnnualMaxCapacityStorage",
"TotalAnnualMinCapacityStorage", "TotalAnnualMaxCapacityInvestmentStorage", "TotalAnnualMinCapacityInvestmentStorage",
"TransmissionCapacityToActivityUnit", "StorageFullLoadHours", "RampRate", "RampingReset"]

append!(paramsneedingdefs, ["NodalDistributionDemand", "NodalDistributionTechnologyCapacity", "NodalDistributionStorageCapacity"])

createviewwithdefaults(db, paramsneedingdefs)
create_other_nemo_indices(db)

logmsg("Created parameter views and indices.", quiet)
# END: Create parameter views showing default values and parameter indices.

# BEGIN: Create temporary tables.
# These tables are created as ordinary tables, not SQLite temporary tables, in order to make them simultaneously visible to multiple Julia processes
create_temp_tables(db)
logmsg("Created temporary tables.", quiet)
# END: Create temporary tables.

# BEGIN: Execute database queries in parallel.
# Parallelization possible for queries instantiated as a DataFrame - this object can be returned from worker processes in a pmap call, while SQLite.Query cannot
# Since instantiation as a DataFrame is costly, it is used selectively (only where needed for other steps in calculatescenario)
querycommands::Dict{String, Tuple{String, String}} = scenario_calc_queries(dbpath, transmissionmodeling,
    in("vproductionbytechnology", varstosavearr), in("vusebytechnology", varstosavearr))

if targetprocs == [1]
    queries = Dict{String, DataFrame}(keys(querycommands) .=> map(run_qry, values(querycommands)))
else
    # Omitting process 1 from WorkerPool improves performance
    queries = Dict{String, DataFrame}(keys(querycommands) .=> pmap(run_qry, WorkerPool(setdiff(targetprocs, [1])), values(querycommands)))
end

logmsg("Executed core database queries.", quiet)
# END: Execute database queries in parallel.

# BEGIN: Define dimensions.
tempquery = SQLite.DBInterface.execute(db, "select val from YEAR order by val")
syear::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # YEAR dimension
tempquery = SQLite.DBInterface.execute(db, "select val from TECHNOLOGY")
stechnology::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # TECHNOLOGY dimension
tempquery = SQLite.DBInterface.execute(db, "select val from TIMESLICE")
stimeslice::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # TIMESLICE dimension
tempquery = SQLite.DBInterface.execute(db, "select val from FUEL")
sfuel::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # FUEL dimension
tempquery = SQLite.DBInterface.execute(db, "select val from EMISSION")
semission::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # EMISSION dimension
tempquery = SQLite.DBInterface.execute(db, "select val from MODE_OF_OPERATION")
smode_of_operation::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # MODE_OF_OPERATION dimension
tempquery = SQLite.DBInterface.execute(db, "select val from REGION")
sregion::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # REGION dimension
tempquery = SQLite.DBInterface.execute(db, "select val from STORAGE")
sstorage::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # STORAGE dimension
tempquery = SQLite.DBInterface.execute(db, "select name from TSGROUP1")
stsgroup1::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :name]))  # Time slice group 1 dimension
tempquery = SQLite.DBInterface.execute(db, "select name from TSGROUP2")
stsgroup2::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :name]))  # Time slice group 2 dimension

if transmissionmodeling
    tempquery = SQLite.DBInterface.execute(db, "select val from NODE")
    snode::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :val]))  # Node dimension
    tempquery = SQLite.DBInterface.execute(db, "select id from TransmissionLine")
    stransmission::Array{String,1} = SQLite.done(tempquery) ? Array{String,1}() : collect(skipmissing(DataFrame(tempquery)[!, :id]))  # Transmission line dimension
end

tsgroup1dict::Dict{Int, Tuple{String, Float64}} = Dict{Int, Tuple{String, Float64}}(row[:order] => (row[:name], row[:multiplier]) for row in
    SQLite.DBInterface.execute(db, "select [order], name, cast (multiplier as real) as multiplier from tsgroup1 order by [order]"))
    # For TSGROUP1, a dictionary mapping orders to tuples of (name, multiplier)
tsgroup2dict::Dict{Int, Tuple{String, Float64}} = Dict{Int, Tuple{String, Float64}}(row[:order] => (row[:name], row[:multiplier]) for row in
    SQLite.DBInterface.execute(db, "select [order], name, cast (multiplier as real) as multiplier from tsgroup2 order by [order]"))
    # For TSGROUP2, a dictionary mapping orders to tuples of (name, multiplier)
ltsgroupdict::Dict{Tuple{Int, Int, Int}, String} = Dict{Tuple{Int, Int, Int}, String}((row[:tg1o], row[:tg2o], row[:lo]) => row[:l] for row in
    SQLite.DBInterface.execute(db, "select ltg.l as l, ltg.lorder as lo, ltg.tg2, tg2.[order] as tg2o, ltg.tg1, tg1.[order] as tg1o
    from LTsGroup ltg, TSGROUP2 tg2, TSGROUP1 tg1
    where
    ltg.tg2 = tg2.name
    and ltg.tg1 = tg1.name"))  # Dictionary of LTsGroup table mapping tuples of (tsgroup1 order, tsgroup2 order, time slice order) to time slice vals

logmsg("Defined dimensions.", quiet)
# END: Define dimensions.

# BEGIN: Define model variables.
modelvarindices::Dict{String, Tuple{JuMP.JuMPContainer,Array{String,1}}} = Dict{String, Tuple{JuMP.JuMPContainer,Array{String,1}}}()
# Dictionary mapping model variable names to tuples of (variable, [index column names]); must have an entry here in order to save
#   variable's results back to database

# Demands
if in("vrateofdemandnn", varstosavearr)
    @variable(jumpmodel, vrateofdemandnn[sregion, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vrateofdemandnn"] = (vrateofdemandnn, ["r","l","f","y"])
end

@variable(jumpmodel, vdemandnn[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vdemandnn"] = (vdemandnn, ["r","l","f","y"])

@variable(jumpmodel, vdemandannualnn[sregion, sfuel, syear] >= 0)
modelvarindices["vdemandannualnn"] = (vdemandannualnn, ["r","f","y"])

logmsg("Defined demand variables.", quiet)

# Storage
@variable(jumpmodel, vstorageleveltsgroup1startnn[sregion, sstorage, stsgroup1, syear] >= 0)
@variable(jumpmodel, vstorageleveltsgroup1endnn[sregion, sstorage, stsgroup1, syear] >= 0)
@variable(jumpmodel, vstorageleveltsgroup2startnn[sregion, sstorage, stsgroup1, stsgroup2, syear] >= 0)
@variable(jumpmodel, vstorageleveltsgroup2endnn[sregion, sstorage, stsgroup1, stsgroup2, syear] >= 0)
@variable(jumpmodel, vstorageleveltsendnn[sregion, sstorage, stimeslice, syear] >= 0)  # Storage level at end of first hour in time slice
@variable(jumpmodel, vstoragelevelyearendnn[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vrateofstoragechargenn[sregion, sstorage, stimeslice, syear] >= 0)
@variable(jumpmodel, vrateofstoragedischargenn[sregion, sstorage, stimeslice, syear] >= 0)
@variable(jumpmodel, vstoragelowerlimit[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vstorageupperlimit[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vaccumulatednewstoragecapacity[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vnewstoragecapacity[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vcapitalinvestmentstorage[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vdiscountedcapitalinvestmentstorage[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vsalvagevaluestorage[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vdiscountedsalvagevaluestorage[sregion, sstorage, syear] >= 0)
@variable(jumpmodel, vtotaldiscountedstoragecost[sregion, sstorage, syear] >= 0)

modelvarindices["vstorageleveltsgroup1startnn"] = (vstorageleveltsgroup1startnn, ["r", "s", "tg1", "y"])
modelvarindices["vstorageleveltsgroup1endnn"] = (vstorageleveltsgroup1endnn, ["r", "s", "tg1", "y"])
modelvarindices["vstorageleveltsgroup2startnn"] = (vstorageleveltsgroup2startnn, ["r", "s", "tg1", "tg2", "y"])
modelvarindices["vstorageleveltsgroup2endnn"] = (vstorageleveltsgroup2endnn, ["r", "s", "tg1", "tg2", "y"])
modelvarindices["vstorageleveltsendnn"] = (vstorageleveltsendnn, ["r", "s", "l", "y"])
modelvarindices["vstoragelevelyearendnn"] = (vstoragelevelyearendnn, ["r", "s", "y"])
modelvarindices["vrateofstoragechargenn"] = (vrateofstoragechargenn, ["r", "s", "l", "y"])
modelvarindices["vrateofstoragedischargenn"] = (vrateofstoragedischargenn, ["r", "s", "l", "y"])
modelvarindices["vstoragelowerlimit"] = (vstoragelowerlimit, ["r", "s", "y"])
modelvarindices["vstorageupperlimit"] = (vstorageupperlimit, ["r", "s", "y"])
modelvarindices["vaccumulatednewstoragecapacity"] = (vaccumulatednewstoragecapacity, ["r", "s", "y"])
modelvarindices["vnewstoragecapacity"] = (vnewstoragecapacity, ["r", "s", "y"])
modelvarindices["vcapitalinvestmentstorage"] = (vcapitalinvestmentstorage, ["r", "s", "y"])
modelvarindices["vdiscountedcapitalinvestmentstorage"] = (vdiscountedcapitalinvestmentstorage, ["r", "s", "y"])
modelvarindices["vsalvagevaluestorage"] = (vsalvagevaluestorage, ["r", "s", "y"])
modelvarindices["vdiscountedsalvagevaluestorage"] = (vdiscountedsalvagevaluestorage, ["r", "s", "y"])
modelvarindices["vtotaldiscountedstoragecost"] = (vtotaldiscountedstoragecost, ["r", "s", "y"])
logmsg("Defined storage variables.", quiet)

# Capacity
@variable(jumpmodel, vnumberofnewtechnologyunits[sregion, stechnology, syear] >= 0, Int)
modelvarindices["vnumberofnewtechnologyunits"] = (vnumberofnewtechnologyunits, ["r", "t", "y"])
@variable(jumpmodel, vnewcapacity[sregion, stechnology, syear] >= 0)
modelvarindices["vnewcapacity"] = (vnewcapacity, ["r", "t", "y"])
@variable(jumpmodel, vaccumulatednewcapacity[sregion, stechnology, syear] >= 0)
modelvarindices["vaccumulatednewcapacity"] = (vaccumulatednewcapacity, ["r", "t", "y"])
@variable(jumpmodel, vtotalcapacityannual[sregion, stechnology, syear] >= 0)
modelvarindices["vtotalcapacityannual"] = (vtotalcapacityannual, ["r", "t", "y"])
logmsg("Defined capacity variables.", quiet)

# Activity
# First, perform some checks to see which variables are needed
local annualactivityupperlimits::Bool
# Indicates whether constraints for TotalTechnologyAnnualActivityUpperLimit should be added to model
local modelperiodactivityupperlimits::Bool
# Indicates whether constraints for TotalTechnologyModelPeriodActivityUpperLimit should be added to model

(annualactivityupperlimits, modelperiodactivityupperlimits) = checkactivityupperlimits(db, 10000.0)

local annualactivitylowerlimits::Bool = true
# Indicates whether constraints for TotalTechnologyAnnualActivityLowerLimit should be added to model
local modelperiodactivitylowerlimits::Bool = true
# Indicates whether constraints for TotalTechnologyModelPeriodActivityLowerLimit should be added to model

queryannualactivitylowerlimit::SQLite.Query = SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as amn
    from TotalTechnologyAnnualActivityLowerLimit_def
    where val > 0")

if SQLite.done(queryannualactivitylowerlimit)
    annualactivitylowerlimits = false
end

querymodelperiodactivitylowerlimit::SQLite.Query = SQLite.DBInterface.execute(db, "select r, t, cast(val as real) as mmn
    from TotalTechnologyModelPeriodActivityLowerLimit_def
    where val > 0")

if SQLite.done(querymodelperiodactivitylowerlimit)
    modelperiodactivitylowerlimits = false
end

@variable(jumpmodel, vrateofactivity[sregion, stimeslice, stechnology, smode_of_operation, syear] >= 0)
modelvarindices["vrateofactivity"] = (vrateofactivity, ["r", "l", "t", "m", "y"])
@variable(jumpmodel, vrateoftotalactivity[sregion, stechnology, stimeslice, syear] >= 0)
modelvarindices["vrateoftotalactivity"] = (vrateoftotalactivity, ["r", "t", "l", "y"])

if (annualactivityupperlimits || annualactivitylowerlimits || modelperiodactivityupperlimits || modelperiodactivitylowerlimits
    || in("vtotaltechnologyannualactivity", varstosavearr))

    @variable(jumpmodel, vtotaltechnologyannualactivity[sregion, stechnology, syear] >= 0)
    modelvarindices["vtotaltechnologyannualactivity"] = (vtotaltechnologyannualactivity, ["r", "t", "y"])
end

@variable(jumpmodel, vtotalannualtechnologyactivitybymode[sregion, stechnology, smode_of_operation, syear] >= 0)
modelvarindices["vtotalannualtechnologyactivitybymode"] = (vtotalannualtechnologyactivitybymode, ["r", "t", "m", "y"])

if modelperiodactivityupperlimits || modelperiodactivitylowerlimits || in("vtotaltechnologymodelperiodactivity", varstosavearr)
    @variable(jumpmodel, vtotaltechnologymodelperiodactivity[sregion, stechnology])
    modelvarindices["vtotaltechnologymodelperiodactivity"] = (vtotaltechnologymodelperiodactivity, ["r", "t"])
end

if in("vproductionbytechnology", varstosavearr)
    # Overall query showing indices of vproductionbytechnology; nodal contributions will be added later if needed
    queryvproductionbytechnologyindices::DataFrames.DataFrame = queries["queryvrateofproductionbytechnologynn"]
end

if restrictvars
    if in("vrateofproductionbytechnologybymodenn", varstosavearr)
        indexdicts = keydicts_parallel(queries["queryvrateofproductionbytechnologybymodenn"], 5, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vrateofproductionbytechnologybymodenn[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
            m=indexdicts[3][[r,l,t]], f=indexdicts[4][[r,l,t,m]], y=indexdicts[5][[r,l,t,m,f]]] >= 0)
    end

    indexdicts = keydicts_parallel(queries["queryvrateofproductionbytechnologynn"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
    @variable(jumpmodel, vrateofproductionbytechnologynn[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
        f=indexdicts[3][[r,l,t]], y=indexdicts[4][[r,l,t,f]]] >= 0)

    indexdicts = keydicts_parallel(queries["queryvproductionbytechnologyannual"], 3, targetprocs)  # Array of Dicts used to restrict indices of vproductionbytechnologyannual
    @variable(jumpmodel, vproductionbytechnologyannual[r=[k[1] for k = keys(indexdicts[1])], t=indexdicts[1][[r]], f=indexdicts[2][[r,t]],
        y=indexdicts[3][[r,t,f]]] >= 0)
else
    in("vrateofproductionbytechnologybymodenn", varstosavearr) &&
        @variable(jumpmodel, vrateofproductionbytechnologybymodenn[sregion, stimeslice, stechnology, smode_of_operation, sfuel, syear] >= 0)
    @variable(jumpmodel, vrateofproductionbytechnologynn[sregion, stimeslice, stechnology, sfuel, syear] >= 0)
    @variable(jumpmodel, vproductionbytechnologyannual[sregion, stechnology, sfuel, syear] >= 0)
end

if in("vrateofproductionbytechnologybymodenn", varstosavearr)
    modelvarindices["vrateofproductionbytechnologybymodenn"] = (vrateofproductionbytechnologybymodenn, ["r", "l", "t", "m", "f", "y"])
end

modelvarindices["vrateofproductionbytechnologynn"] = (vrateofproductionbytechnologynn, ["r","l","t","f","y"])
modelvarindices["vproductionbytechnologyannual"] = (vproductionbytechnologyannual, ["r","t","f","y"])

@variable(jumpmodel, vrateofproduction[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vrateofproduction"] = (vrateofproduction, ["r", "l", "f", "y"])
@variable(jumpmodel, vrateofproductionnn[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vrateofproductionnn"] = (vrateofproductionnn, ["r", "l", "f", "y"])
@variable(jumpmodel, vproductionnn[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vproductionnn"] = (vproductionnn, ["r","l","f","y"])

if in("vusebytechnology", varstosavearr)
    # Overall query showing indices of vusebytechnology; nodal contributions will be added later if needed
    queryvusebytechnologyindices::DataFrames.DataFrame = queries["queryvrateofusebytechnologynn"]
end

if restrictvars
    if in("vrateofusebytechnologybymodenn", varstosavearr)
        indexdicts = keydicts_parallel(queries["queryvrateofusebytechnologybymodenn"], 5, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vrateofusebytechnologybymodenn[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
            m=indexdicts[3][[r,l,t]], f=indexdicts[4][[r,l,t,m]], y=indexdicts[5][[r,l,t,m,f]]] >= 0)
    end

    indexdicts = keydicts_parallel(queries["queryvrateofusebytechnologynn"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
    @variable(jumpmodel, vrateofusebytechnologynn[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
        f=indexdicts[3][[r,l,t]], y=indexdicts[4][[r,l,t,f]]] >= 0)

    indexdicts = keydicts_parallel(queries["queryvusebytechnologyannual"], 3, targetprocs)  # Array of Dicts used to restrict indices of vusebytechnologyannual
    @variable(jumpmodel, vusebytechnologyannual[r=[k[1] for k = keys(indexdicts[1])], t=indexdicts[1][[r]], f=indexdicts[2][[r,t]],
        y=indexdicts[3][[r,t,f]]] >= 0)
else
    in("vrateofusebytechnologybymodenn", varstosavearr) &&
        @variable(jumpmodel, vrateofusebytechnologybymodenn[sregion, stimeslice, stechnology, smode_of_operation, sfuel, syear] >= 0)
    @variable(jumpmodel, vrateofusebytechnologynn[sregion, stimeslice, stechnology, sfuel, syear] >= 0)
    @variable(jumpmodel, vusebytechnologyannual[sregion, stechnology, sfuel, syear] >= 0)
end

if in("vrateofusebytechnologybymodenn", varstosavearr)
    modelvarindices["vrateofusebytechnologybymodenn"] = (vrateofusebytechnologybymodenn, ["r", "l", "t", "m", "f", "y"])
end

modelvarindices["vrateofusebytechnologynn"] = (vrateofusebytechnologynn, ["r","l","t","f","y"])

modelvarindices["vusebytechnologyannual"] = (vusebytechnologyannual, ["r","t","f","y"])

@variable(jumpmodel, vrateofuse[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vrateofuse"] = (vrateofuse, ["r", "l", "f", "y"])
@variable(jumpmodel, vrateofusenn[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vrateofusenn"] = (vrateofusenn, ["r", "l", "f", "y"])
@variable(jumpmodel, vusenn[sregion, stimeslice, sfuel, syear] >= 0)
modelvarindices["vusenn"] = (vusenn, ["r", "l", "f", "y"])

@variable(jumpmodel, vtrade[sregion, sregion, stimeslice, sfuel, syear])
modelvarindices["vtrade"] = (vtrade, ["r", "rr", "l", "f", "y"])
@variable(jumpmodel, vtradeannual[sregion, sregion, sfuel, syear])
modelvarindices["vtradeannual"] = (vtradeannual, ["r", "rr", "f", "y"])
@variable(jumpmodel, vproductionannualnn[sregion, sfuel, syear] >= 0)
modelvarindices["vproductionannualnn"] = (vproductionannualnn, ["r", "f", "y"])
@variable(jumpmodel, vuseannualnn[sregion, sfuel, syear] >= 0)
modelvarindices["vuseannualnn"] = (vuseannualnn, ["r", "f", "y"])
logmsg("Defined activity variables.", quiet)

# Costing
@variable(jumpmodel, vcapitalinvestment[sregion, stechnology, syear] >= 0)
modelvarindices["vcapitalinvestment"] = (vcapitalinvestment, ["r", "t", "y"])
@variable(jumpmodel, vdiscountedcapitalinvestment[sregion, stechnology, syear] >= 0)
modelvarindices["vdiscountedcapitalinvestment"] = (vdiscountedcapitalinvestment, ["r", "t", "y"])
@variable(jumpmodel, vsalvagevalue[sregion, stechnology, syear] >= 0)
modelvarindices["vsalvagevalue"] = (vsalvagevalue, ["r", "t", "y"])
@variable(jumpmodel, vdiscountedsalvagevalue[sregion, stechnology, syear] >= 0)
modelvarindices["vdiscountedsalvagevalue"] = (vdiscountedsalvagevalue, ["r", "t", "y"])
@variable(jumpmodel, voperatingcost[sregion, stechnology, syear] >= 0)
modelvarindices["voperatingcost"] = (voperatingcost, ["r", "t", "y"])
@variable(jumpmodel, vdiscountedoperatingcost[sregion, stechnology, syear] >= 0)
modelvarindices["vdiscountedoperatingcost"] = (vdiscountedoperatingcost, ["r", "t", "y"])
@variable(jumpmodel, vannualvariableoperatingcost[sregion, stechnology, syear] >= 0)
modelvarindices["vannualvariableoperatingcost"] = (vannualvariableoperatingcost, ["r", "t", "y"])
@variable(jumpmodel, vannualfixedoperatingcost[sregion, stechnology, syear] >= 0)
modelvarindices["vannualfixedoperatingcost"] = (vannualfixedoperatingcost, ["r", "t", "y"])
@variable(jumpmodel, vtotaldiscountedcostbytechnology[sregion, stechnology, syear] >= 0)
modelvarindices["vtotaldiscountedcostbytechnology"] = (vtotaldiscountedcostbytechnology, ["r", "t", "y"])
@variable(jumpmodel, vtotaldiscountedcost[sregion, syear] >= 0)
modelvarindices["vtotaldiscountedcost"] = (vtotaldiscountedcost, ["r", "y"])

if in("vmodelperiodcostbyregion", varstosavearr)
    @variable(jumpmodel, vmodelperiodcostbyregion[sregion] >= 0)
    modelvarindices["vmodelperiodcostbyregion"] = (vmodelperiodcostbyregion, ["r"])
end

logmsg("Defined costing variables.", quiet)

# Reserve margin
@variable(jumpmodel, vtotalcapacityinreservemargin[sregion, syear] >= 0)
modelvarindices["vtotalcapacityinreservemargin"] = (vtotalcapacityinreservemargin, ["r", "y"])
@variable(jumpmodel, vdemandneedingreservemargin[sregion, stimeslice, syear] >= 0)
modelvarindices["vdemandneedingreservemargin"] = (vdemandneedingreservemargin, ["r", "l", "y"])

logmsg("Defined reserve margin variables.", quiet)

# RE target
@variable(jumpmodel, vtotalreproductionannual[sregion, syear])
@variable(jumpmodel, vretotalproductionoftargetfuelannual[sregion, syear])

modelvarindices["vtotalreproductionannual"] = (vtotalreproductionannual, ["r", "y"])
modelvarindices["vretotalproductionoftargetfuelannual"] = (vretotalproductionoftargetfuelannual, ["r", "y"])
logmsg("Defined renewable energy target variables.", quiet)

# Emissions
if in("vannualtechnologyemissionbymode", varstosavearr)
    @variable(jumpmodel, vannualtechnologyemissionbymode[sregion, stechnology, semission, smode_of_operation, syear] >= 0)
    modelvarindices["vannualtechnologyemissionbymode"] = (vannualtechnologyemissionbymode, ["r", "t", "e", "m", "y"])
end

@variable(jumpmodel, vannualtechnologyemission[sregion, stechnology, semission, syear] >= 0)
modelvarindices["vannualtechnologyemission"] = (vannualtechnologyemission, ["r", "t", "e", "y"])

if in("vannualtechnologyemissionpenaltybyemission", varstosavearr)
    @variable(jumpmodel, vannualtechnologyemissionpenaltybyemission[sregion, stechnology, semission, syear] >= 0)
    modelvarindices["vannualtechnologyemissionpenaltybyemission"] = (vannualtechnologyemissionpenaltybyemission, ["r", "t", "e", "y"])
end

@variable(jumpmodel, vannualtechnologyemissionspenalty[sregion, stechnology, syear] >= 0)
modelvarindices["vannualtechnologyemissionspenalty"] = (vannualtechnologyemissionspenalty, ["r", "t", "y"])
@variable(jumpmodel, vdiscountedtechnologyemissionspenalty[sregion, stechnology, syear] >= 0)
modelvarindices["vdiscountedtechnologyemissionspenalty"] = (vdiscountedtechnologyemissionspenalty, ["r", "t", "y"])
@variable(jumpmodel, vannualemissions[sregion, semission, syear] >= 0)
modelvarindices["vannualemissions"] = (vannualemissions, ["r", "e", "y"])
@variable(jumpmodel, vmodelperiodemissions[sregion, semission] >= 0)
modelvarindices["vmodelperiodemissions"] = (vmodelperiodemissions, ["r", "e"])

logmsg("Defined emissions variables.", quiet)

# Transmission
if transmissionmodeling
    if in("vproductionbytechnology", varstosavearr)
        queryvproductionbytechnologynodal::SQLite.Query = SQLite.DBInterface.execute(db, "select n.r as r, ntc.n as n, ys.l as l, ntc.t as t, oar.f as f, ntc.y as y,
            cast(ys.val as real) as ys
        from NodalDistributionTechnologyCapacity_def ntc, YearSplit_def ys, NODE n,
        TransmissionModelingEnabled tme,
        (select distinct r, t, f, y
        from OutputActivityRatio_def
        where val <> 0) oar
        where ntc.val > 0
        and ntc.y = ys.y
        and ntc.n = n.val
        and tme.r = n.r and tme.f = oar.f and tme.y = ntc.y
        and oar.r = n.r and oar.t = ntc.t and oar.y = ntc.y
        order by n.r, ys.l, ntc.t, oar.f, ntc.y")

        queryvproductionbytechnologyindices = vcat(queryvproductionbytechnologyindices,
        queries["queryvproductionbytechnologyindices_nodalpart"])
    end

    if in("vusebytechnology", varstosavearr)
        queryvusebytechnologynodal::SQLite.Query = SQLite.DBInterface.execute(db, "select n.r as r, ntc.n as n, ys.l as l, ntc.t as t, iar.f as f, ntc.y as y,
            cast(ys.val as real) as ys
        from NodalDistributionTechnologyCapacity_def ntc, YearSplit_def ys, NODE n,
        TransmissionModelingEnabled tme,
        (select distinct r, t, f, y
        from InputActivityRatio_def
        where val <> 0) iar
        where ntc.val > 0
        and ntc.y = ys.y
        and ntc.n = n.val
        and tme.r = n.r and tme.f = iar.f and tme.y = ntc.y
        and iar.r = n.r and iar.t = ntc.t and iar.y = ntc.y
        order by n.r, ys.l, ntc.t, iar.f, ntc.y")

        queryvusebytechnologyindices = vcat(queryvusebytechnologyindices,
        queries["queryvusebytechnologyindices_nodalpart"])
    end

    # Activity
    if restrictvars
        indexdicts = keydicts_parallel(queries["queryvrateofactivitynodal"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vrateofactivitynodal[n=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[n]], t=indexdicts[2][[n,l]],
            m=indexdicts[3][[n,l,t]], y=indexdicts[4][[n,l,t,m]]] >= 0)

        indexdicts = keydicts_parallel(queries["queryvrateofproductionbytechnologynodal"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vrateofproductionbytechnologynodal[n=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[n]], t=indexdicts[2][[n,l]],
            f=indexdicts[3][[n,l,t]], y=indexdicts[4][[n,l,t,f]]] >= 0)

        indexdicts = keydicts_parallel(queries["queryvrateofusebytechnologynodal"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vrateofusebytechnologynodal[n=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[n]], t=indexdicts[2][[n,l]],
            f=indexdicts[3][[n,l,t]], y=indexdicts[4][[n,l,t,f]]] >= 0)

        indexdicts = keydicts_parallel(queries["queryvtransmissionbyline"], 3, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vtransmissionbyline[tr=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[tr]], f=indexdicts[2][[tr,l]],
            y=indexdicts[3][[tr,l,f]]])
    else
        @variable(jumpmodel, vrateofactivitynodal[snode, stimeslice, stechnology, smode_of_operation, syear] >= 0)
        @variable(jumpmodel, vrateofproductionbytechnologynodal[snode, stimeslice, stechnology, sfuel, syear] >= 0)
        @variable(jumpmodel, vrateofusebytechnologynodal[snode, stimeslice, stechnology, sfuel, syear] >= 0)
        @variable(jumpmodel, vtransmissionbyline[stransmission, stimeslice, sfuel, syear])
    end

    modelvarindices["vrateofactivitynodal"] = (vrateofactivitynodal, ["n", "l", "t", "m", "y"])
    modelvarindices["vrateofproductionbytechnologynodal"] = (vrateofproductionbytechnologynodal, ["n", "l", "t", "f", "y"])
    modelvarindices["vrateofusebytechnologynodal"] = (vrateofusebytechnologynodal, ["n", "l", "t", "f", "y"])
    # Note: n1 is from node; n2 is to node
    modelvarindices["vtransmissionbyline"] = (vtransmissionbyline, ["tr", "l", "f", "y"])

    @variable(jumpmodel, vrateoftotalactivitynodal[snode, stechnology, stimeslice, syear] >= 0)
    modelvarindices["vrateoftotalactivitynodal"] = (vrateoftotalactivitynodal, ["n", "t", "l", "y"])

    @variable(jumpmodel, vrateofproductionnodal[snode, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vrateofproductionnodal"] = (vrateofproductionnodal, ["n", "l", "f", "y"])

    @variable(jumpmodel, vrateofusenodal[snode, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vrateofusenodal"] = (vrateofusenodal, ["n", "l", "f", "y"])

    @variable(jumpmodel, vproductionnodal[snode, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vproductionnodal"] = (vproductionnodal, ["n","l","f","y"])

    @variable(jumpmodel, vproductionannualnodal[snode, sfuel, syear] >= 0)
    modelvarindices["vproductionannualnodal"] = (vproductionannualnodal, ["n","f","y"])

    @variable(jumpmodel, vusenodal[snode, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vusenodal"] = (vusenodal, ["n","l","f","y"])

    @variable(jumpmodel, vuseannualnodal[snode, sfuel, syear] >= 0)
    modelvarindices["vuseannualnodal"] = (vuseannualnodal, ["n","f","y"])

    # Demands
    @variable(jumpmodel, vdemandnodal[snode, stimeslice, sfuel, syear] >= 0)
    modelvarindices["vdemandnodal"] = (vdemandnodal, ["n","l","f","y"])

    @variable(jumpmodel, vdemandannualnodal[snode, sfuel, syear] >= 0)
    modelvarindices["vdemandannualnodal"] = (vdemandannualnodal, ["n","f","y"])

    # Capacity and other
    # vtransmissionannual is net annual transmission from n in energy terms
    @variable(jumpmodel, vtransmissionannual[snode, sfuel, syear])
    modelvarindices["vtransmissionannual"] = (vtransmissionannual, ["n","f","y"])

    # Indicates whether tr is built in year
    if continuoustransmission
        @variable(jumpmodel, 0 <= vtransmissionbuilt[stransmission, syear] <= 1)
    else
        @variable(jumpmodel, vtransmissionbuilt[stransmission, syear], Bin)
    end

    modelvarindices["vtransmissionbuilt"] = (vtransmissionbuilt, ["tr","y"])

    # Indicates whether tr exists (exogenously or endogenously) in year (0 or 1 if vtransmissionbuilt is Bin, otherwise between 0 and 1)
    @variable(jumpmodel, 0 <= vtransmissionexists[stransmission, syear] <= 1)
    modelvarindices["vtransmissionexists"] = (vtransmissionexists, ["tr","y"])

    # 1 = DC optimized power flow, 2 = DCOPF with disjunctive relaxation
    if in(1, transmissionmodelingtypes) || in(2, transmissionmodelingtypes)
        @variable(jumpmodel, -pi <= vvoltageangle[snode, stimeslice, syear] <= pi)
        modelvarindices["vvoltageangle"] = (vvoltageangle, ["n","l","y"])
    end

    # Storage
    if restrictvars
        indexdicts = keydicts_parallel(queries["queryvstorageleveltsgroup1"], 3, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vstorageleveltsgroup1startnodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], tg1=indexdicts[2][[n,s]],
            y=indexdicts[3][[n,s,tg1]]] >= 0)
        @variable(jumpmodel, vstorageleveltsgroup1endnodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], tg1=indexdicts[2][[n,s]],
            y=indexdicts[3][[n,s,tg1]]] >= 0)

        indexdicts = keydicts_parallel(queries["queryvstorageleveltsgroup2"], 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vstorageleveltsgroup2startnodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], tg1=indexdicts[2][[n,s]],
            tg2=indexdicts[3][[n,s,tg1]], y=indexdicts[4][[n,s,tg1,tg2]]] >= 0)
        @variable(jumpmodel, vstorageleveltsgroup2endnodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], tg1=indexdicts[2][[n,s]],
            tg2=indexdicts[3][[n,s,tg1]], y=indexdicts[4][[n,s,tg1,tg2]]] >= 0)

        indexdicts = keydicts_parallel(queries["queryvstoragelevelts"], 3, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vstorageleveltsendnodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], l=indexdicts[2][[n,s]],
            y=indexdicts[3][[n,s,l]]] >= 0)
        @variable(jumpmodel, vrateofstoragechargenodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], l=indexdicts[2][[n,s]],
            y=indexdicts[3][[n,s,l]]] >= 0)
        @variable(jumpmodel, vrateofstoragedischargenodal[n=[k[1] for k = keys(indexdicts[1])], s=indexdicts[1][[n]], l=indexdicts[2][[n,s]],
            y=indexdicts[3][[n,s,l]]] >= 0)
    else
        @variable(jumpmodel, vstorageleveltsgroup1startnodal[snode, sstorage, stsgroup1, syear] >= 0)
        @variable(jumpmodel, vstorageleveltsgroup1endnodal[snode, sstorage, stsgroup1, syear] >= 0)
        @variable(jumpmodel, vstorageleveltsgroup2startnodal[snode, sstorage, stsgroup1, stsgroup2, syear] >= 0)
        @variable(jumpmodel, vstorageleveltsgroup2endnodal[snode, sstorage, stsgroup1, stsgroup2, syear] >= 0)
        @variable(jumpmodel, vstorageleveltsendnodal[snode, sstorage, stimeslice, syear] >= 0)  # Storage level at end of first hour in time slice
        @variable(jumpmodel, vrateofstoragechargenodal[snode, sstorage, stimeslice, syear] >= 0)
        @variable(jumpmodel, vrateofstoragedischargenodal[snode, sstorage, stimeslice, syear] >= 0)
    end

    @variable(jumpmodel, vstoragelevelyearendnodal[snode, sstorage, syear] >= 0)

    modelvarindices["vstorageleveltsgroup1startnodal"] = (vstorageleveltsgroup1startnodal, ["n", "s", "tg1", "y"])
    modelvarindices["vstorageleveltsgroup1endnodal"] = (vstorageleveltsgroup1endnodal, ["n", "s", "tg1", "y"])
    modelvarindices["vstorageleveltsgroup2startnodal"] = (vstorageleveltsgroup2startnodal, ["n", "s", "tg1", "tg2", "y"])
    modelvarindices["vstorageleveltsgroup2endnodal"] = (vstorageleveltsgroup2endnodal, ["n", "s", "tg1", "tg2", "y"])
    modelvarindices["vstorageleveltsendnodal"] = (vstorageleveltsendnodal, ["n", "s", "l", "y"])
    modelvarindices["vrateofstoragechargenodal"] = (vrateofstoragechargenodal, ["n", "s", "l", "y"])
    modelvarindices["vrateofstoragedischargenodal"] = (vrateofstoragedischargenodal, ["n", "s", "l", "y"])
    modelvarindices["vstoragelevelyearendnodal"] = (vstoragelevelyearendnodal, ["n", "s", "y"])

    # Costing
    @variable(jumpmodel, vcapitalinvestmenttransmission[stransmission, syear] >= 0)
    modelvarindices["vcapitalinvestmenttransmission"] = (vcapitalinvestmenttransmission, ["tr","y"])
    @variable(jumpmodel, vdiscountedcapitalinvestmenttransmission[stransmission, syear] >= 0)
    modelvarindices["vdiscountedcapitalinvestmenttransmission"] = (vdiscountedcapitalinvestmenttransmission, ["tr","y"])
    @variable(jumpmodel, vsalvagevaluetransmission[stransmission, syear] >= 0)
    modelvarindices["vsalvagevaluetransmissionvsalvagevaluetransmission"] = (vsalvagevaluetransmission, ["tr","y"])
    @variable(jumpmodel, vdiscountedsalvagevaluetransmission[stransmission, syear] >= 0)
    modelvarindices["vdiscountedsalvagevaluetransmission"] = (vdiscountedsalvagevaluetransmission, ["tr","y"])
    @variable(jumpmodel, voperatingcosttransmission[stransmission, syear] >= 0)
    modelvarindices["voperatingcosttransmission"] = (voperatingcosttransmission, ["tr","y"])
    @variable(jumpmodel, vdiscountedoperatingcosttransmission[stransmission, syear] >= 0)
    modelvarindices["vdiscountedoperatingcosttransmission"] = (vdiscountedoperatingcosttransmission, ["tr","y"])
    @variable(jumpmodel, vtotaldiscountedtransmissioncostbyregion[sregion, syear] >= 0)
    modelvarindices["vtotaldiscountedtransmissioncostbyregion"] = (vtotaldiscountedtransmissioncostbyregion, ["r","y"])

    logmsg("Defined transmission variables.", quiet)
end  # if transmissionmodeling

# Combined nodal + non-nodal variables
if in("vproductionbytechnology", varstosavearr)
    if restrictvars
        indexdicts = keydicts_parallel(queryvproductionbytechnologyindices, 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vproductionbytechnology[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
            f=indexdicts[3][[r,l,t]], y=indexdicts[4][[r,l,t,f]]] >= 0)
    else
        @variable(jumpmodel, vproductionbytechnology[sregion, stimeslice, stechnology, sfuel, syear] >= 0)
    end

    modelvarindices["vproductionbytechnology"] = (vproductionbytechnology, ["r","l","t","f","y"])
end

if in("vusebytechnology", varstosavearr)
    if restrictvars
        indexdicts = keydicts_parallel(queryvusebytechnologyindices, 4, targetprocs)  # Array of Dicts used to restrict indices of following variable
        @variable(jumpmodel, vusebytechnology[r=[k[1] for k = keys(indexdicts[1])], l=indexdicts[1][[r]], t=indexdicts[2][[r,l]],
            f=indexdicts[3][[r,l,t]], y=indexdicts[4][[r,l,t,f]]] >= 0)
    else
        @variable(jumpmodel, vusebytechnology[sregion, stimeslice, stechnology, sfuel, syear] >= 0)
    end

    modelvarindices["vusebytechnology"] = (vusebytechnology, ["r","l","t","f","y"])
end

logmsg("Defined combined nodal and non-nodal variables.", quiet)

logmsg("Finished defining model variables.", quiet)
# END: Define model variables.

# BEGIN: Define model constraints.

# A few variables used in constraint construction
local lastkeys::Array{String, 1} = Array{String, 1}()  # Array of last key values processed in constraint query loops
local lastvals::Array{Float64, 1} = Array{Float64, 1}()  # Array of last float values saved in constraint query loops
local lastvalsint::Array{Int64, 1} = Array{Int64, 1}()  # Array of last integer values saved in constraint query loops
local sumexps::Array{AffExpr, 1} = Array{AffExpr, 1}()  # Array of sums of variables assembled in constraint query loops

# BEGIN: EQ_SpecifiedDemand.
queryvrateofdemandnn::SQLite.Query = SQLite.DBInterface.execute(db, "select sdp.r as r, sdp.f as f, sdp.l as l, sdp.y as y,
cast(sdp.val as real) as specifieddemandprofile, cast(sad.val as real) as specifiedannualdemand,
cast(ys.val as real) as ys
from SpecifiedDemandProfile_def sdp, SpecifiedAnnualDemand_def sad, YearSplit_def ys
left join TransmissionModelingEnabled tme on tme.r = sad.r and tme.f = sad.f and tme.y = sad.y
where sad.r = sdp.r and sad.f = sdp.f and sad.y = sdp.y
and ys.l = sdp.l and ys.y = sdp.y
and sdp.val <> 0 and sad.val <> 0 and ys.val <> 0
and tme.id is null")

if in("vrateofdemandnn", varstosavearr)
    ceq_specifieddemand::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in queryvrateofdemandnn
        push!(ceq_specifieddemand, @constraint(jumpmodel, row[:specifiedannualdemand] * row[:specifieddemandprofile] / row[:ys]
            == vrateofdemandnn[row[:r], row[:l], row[:f], row[:y]]))
    end

    SQLite.reset!(queryvrateofdemandnn)

    length(ceq_specifieddemand) > 0 && logmsg("Created constraint EQ_SpecifiedDemand.", quiet)
end
# END: EQ_SpecifiedDemand.

# BEGIN: CAa1_TotalNewCapacity.
caa1_totalnewcapacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vnewcapacity sum

for row in SQLite.DBInterface.execute(db,"select r.val as r, t.val as t, y.val as y, yy.val as yy
from REGION r, TECHNOLOGY t, YEAR y, OperationalLife_def ol, YEAR yy
where ol.r = r.val and ol.t = t.val
and y.val - yy.val < ol.val and y.val - yy.val >=0
order by r.val, t.val, y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(caa1_totalnewcapacity, @constraint(jumpmodel, sumexps[1] == vaccumulatednewcapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vnewcapacity[r,t,row[:yy]])

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(caa1_totalnewcapacity, @constraint(jumpmodel, sumexps[1] == vaccumulatednewcapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(caa1_totalnewcapacity) > 0 && logmsg("Created constraint CAa1_TotalNewCapacity.", quiet)
# END: CAa1_TotalNewCapacity.

# BEGIN: CAa2_TotalAnnualCapacity.
caa2_totalannualcapacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db,"select r.val as r, t.val as t, y.val as y, cast(rc.val as real) as rc
from REGION r, TECHNOLOGY t, YEAR y
left join ResidualCapacity_def rc on rc.r = r.val and rc.t = t.val and rc.y = y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]
    local rc = ismissing(row[:rc]) ? 0 : row[:rc]

    push!(caa2_totalannualcapacity, @constraint(jumpmodel, vaccumulatednewcapacity[r,t,y] + rc == vtotalcapacityannual[r,t,y]))
end

length(caa2_totalannualcapacity) > 0 && logmsg("Created constraint CAa2_TotalAnnualCapacity.", quiet)
# END: CAa2_TotalAnnualCapacity.

# BEGIN: VRateOfActivity1.
# This constraint sets activity to sum of nodal activity for technologies involved in nodal modeling.
vrateofactivity1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = m, lastkeys[5] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivitynodal sum

for row in SQLite.DBInterface.execute(db,
"select n.r as r, l.val as l, ntc.t as t, ar.m as m, ntc.y as y, ntc.n as n
from NodalDistributionTechnologyCapacity_def ntc, node n,
	TransmissionModelingEnabled tme, TIMESLICE l,
(select r, t, f, m, y from OutputActivityRatio_def
where val <> 0
union
select r, t, f, m, y from InputActivityRatio_def
where val <> 0) ar
where ntc.val > 0
and ntc.n = n.val
and tme.r = n.r and tme.f = ar.f and tme.y = ntc.y
and ar.r = n.r and ar.t = ntc.t and ar.y = ntc.y
order by l.val, ntc.t, ar.m, ntc.y, n.r")
    local r = row[:r]
    local l = row[:l]
    local t = row[:t]
    local m = row[:m]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || m != lastkeys[4] || y != lastkeys[5])
        # Create constraint
        push!(vrateofactivity1, @constraint(jumpmodel, sumexps[1] == vrateofactivity[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivitynodal[row[:n],l,t,m,y])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = t
    lastkeys[4] = m
    lastkeys[5] = y
end

if isassigned(lastkeys, 1)
    push!(vrateofactivity1, @constraint(jumpmodel, sumexps[1] == vrateofactivity[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
end

length(vrateofactivity1) > 0 && logmsg("Created constraint VRateOfActivity1.", quiet)
# END: VRateOfActivity1.

# BEGIN: RampRate.
ramprate::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "with ltgs as (select ltg.tg1, tg1.[order] as tg1o, ltg.tg2, tg2.[order] as tg2o, ltg.l, ltg.lorder,
lag(ltg.l) over (order by tg1.[order], tg2.[order], ltg.lorder) as prior_l
from LTsGroup ltg, TSGROUP1 tg1, TSGROUP2 tg2
where ltg.tg1 = tg1.name
and ltg.tg2 = tg2.name),
nodal as (select ntc.n as n, n.r as r, ntc.t as t, ar.m as m, ntc.y as y
from NodalDistributionTechnologyCapacity_def ntc, node n,
	TransmissionModelingEnabled tme,
(select r, t, f, m, y from OutputActivityRatio_def
where val <> 0
union
select r, t, f, m, y from InputActivityRatio_def
where val <> 0) ar
where ntc.val > 0
and ntc.n = n.val
and tme.r = n.r and tme.f = ar.f and tme.y = ntc.y
and ar.r = n.r and ar.t = ntc.t and ar.y = ntc.y)
select * from (
select rr.r, rr.t, rr.y, rr.l, m.val as m, cast(rr.val as real) as rr, ltgs.tg1o, ltgs.tg2o, ltgs.lorder, ltgs.prior_l,
case rrs.val when 0 then 0 when 1 then 1 when 2 then 2 else 2 end as rrs,
cast(cf.val as real) as cf, cast(cta.val as real) as cta
from RampRate_def rr, ltgs, CapacityFactor_def cf, CapacityToActivityUnit_def cta, MODE_OF_OPERATION m
left join RampingReset_def rrs on rr.r = rrs.r
left join nodal on rr.r = nodal.r and rr.t = nodal.t and rr.y = nodal.y and nodal.m = m.val
where rr.l = ltgs.l
and rr.val <> 1.0
and rr.r = cf.r and rr.t = cf.t and rr.l = cf.l and rr.y = cf.y
and rr.r = cta.r and rr.t = cta.t
and nodal.n is null
)
where
not (tg1o = 1 and tg2o = 1 and lorder = 1)
and not (rrs >= 1 and tg2o = 1 and lorder = 1)
and not (rrs = 2 and lorder = 1)")
    local r = row[:r]
    local t = row[:t]
    local l = row[:l]
    local y = row[:y]
    local m = row[:m]
    local prior_l = row[:prior_l]

    push!(ramprate, @constraint(jumpmodel, vrateofactivity[r,l,t,m,y] <= vrateofactivity[r,prior_l,t,m,y]
        + vtotalcapacityannual[r,t,y] * row[:rr] * row[:cf] * row[:cta]))
    push!(ramprate, @constraint(jumpmodel, vrateofactivity[r,l,t,m,y] >= vrateofactivity[r,prior_l,t,m,y]
        - vtotalcapacityannual[r,t,y] * row[:rr] * row[:cf] * row[:cta]))
end

length(ramprate) > 0 && logmsg("Created constraint RampRate.", quiet)
# END: RampRate.

# BEGIN: RampRateTr.
if transmissionmodeling
    rampratetr::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "with ltgs as (select ltg.tg1, tg1.[order] as tg1o, ltg.tg2, tg2.[order] as tg2o, ltg.l, ltg.lorder,
    lag(ltg.l) over (order by tg1.[order], tg2.[order], ltg.lorder) as prior_l
    from LTsGroup ltg, TSGROUP1 tg1, TSGROUP2 tg2
    where ltg.tg1 = tg1.name
    and ltg.tg2 = tg2.name)
    select * from (
    select rr.r, ntc.n, rr.t, rr.y, rr.l, ar.m, cast(rr.val as real) as rr, ltgs.tg1o, ltgs.tg2o, ltgs.lorder, ltgs.prior_l,
    case rrs.val when 0 then 0 when 1 then 1 when 2 then 2 else 2 end as rrs,
    cast(cf.val as real) as cf, cast(cta.val as real) as cta, cast(ntc.val as real) as ntc
    from RampRate_def rr, ltgs, CapacityFactor_def cf, CapacityToActivityUnit_def cta, NodalDistributionTechnologyCapacity_def ntc,
    	node n, TransmissionModelingEnabled tme,
    	(select r, t, f, m, y from OutputActivityRatio_def
    	where val <> 0
    	union
    	select r, t, f, m, y from InputActivityRatio_def
    	where val <> 0) ar
    left join RampingReset_def rrs on rr.r = rrs.r
    where rr.l = ltgs.l
    and rr.val <> 1.0
    and rr.r = cf.r and rr.t = cf.t and rr.l = cf.l and rr.y = cf.y
    and rr.r = cta.r and rr.t = cta.t
    and ntc.n = n.val
    and rr.r = n.r and rr.t = ntc.t and rr.y = ntc.y and ntc.val > 0
    and rr.r = tme.r and tme.f = ar.f and rr.y = tme.y
    and rr.r = ar.r and rr.t = ar.t and rr.y = ar.y
    )
    where
    not (tg1o = 1 and tg2o = 1 and lorder = 1)
    and not (rrs >= 1 and tg2o = 1 and lorder = 1)
    and not (rrs = 2 and lorder = 1)")
        local r = row[:r]
        local n = row[:n]
        local t = row[:t]
        local l = row[:l]
        local y = row[:y]
        local m = row[:m]
        local prior_l = row[:prior_l]

        push!(rampratetr, @constraint(jumpmodel, vrateofactivitynodal[n,l,t,m,y] <= vrateofactivitynodal[n,prior_l,t,m,y]
            + vtotalcapacityannual[r,t,y] * row[:ntc] * row[:rr] * row[:cf] * row[:cta]))
        push!(rampratetr, @constraint(jumpmodel, vrateofactivitynodal[n,l,t,m,y] >= vrateofactivitynodal[n,prior_l,t,m,y]
            - vtotalcapacityannual[r,t,y] * row[:ntc] * row[:rr] * row[:cf] * row[:cta]))
    end

    length(rampratetr) > 0 && logmsg("Created constraint RampRateTr.", quiet)
end
# END: RampRateTr.

# BEGIN: CAa3_TotalActivityOfEachTechnology.
caa3_totalactivityofeachtechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, t, l, y) in Base.product(sregion, stechnology, stimeslice, syear)
    push!(caa3_totalactivityofeachtechnology, @constraint(jumpmodel, sum([vrateofactivity[r,l,t,m,y] for m = smode_of_operation])
        == vrateoftotalactivity[r,t,l,y]))
end

length(caa3_totalactivityofeachtechnology) > 0 && logmsg("Created constraint CAa3_TotalActivityOfEachTechnology.", quiet)
# END: CAa3_TotalActivityOfEachTechnology.

# BEGIN: CAa3Tr_TotalActivityOfEachTechnology.
if transmissionmodeling
    caa3tr_totalactivityofeachtechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = t, lastkeys[3] = l, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivitynodal sum

    for row in DataFrames.eachrow(queries["queryvrateofactivitynodal"])
        local n = row[:n]
        local t = row[:t]
        local l = row[:l]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || t != lastkeys[2] || l != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(caa3tr_totalactivityofeachtechnology, @constraint(jumpmodel, sumexps[1] == vrateoftotalactivitynodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofactivitynodal[n,l,t,row[:m],y])

        lastkeys[1] = n
        lastkeys[2] = t
        lastkeys[3] = l
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(caa3tr_totalactivityofeachtechnology, @constraint(jumpmodel, sumexps[1] == vrateoftotalactivitynodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end

    length(caa3tr_totalactivityofeachtechnology) > 0 && logmsg("Created constraint CAa3Tr_TotalActivityOfEachTechnology.", quiet)
end
# END: CAa3Tr_TotalActivityOfEachTechnology.

# BEGIN: CAa4_Constraint_Capacity.
caa4_constraint_capacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db,"select r.val as r, l.val as l, t.val as t, y.val as y,
    cast(cf.val as real) as cf, cast(cta.val as real) as cta
from REGION r, TIMESLICE l, TECHNOLOGY t, YEAR y, CapacityFactor_def cf, CapacityToActivityUnit_def cta
where cf.r = r.val and cf.t = t.val and cf.l = l.val and cf.y = y.val
and cta.r = r.val and cta.t = t.val")
    local r = row[:r]
    local t = row[:t]
    local l = row[:l]
    local y = row[:y]

    push!(caa4_constraint_capacity, @constraint(jumpmodel, vrateoftotalactivity[r,t,l,y]
        <= vtotalcapacityannual[r,t,y] * row[:cf] * row[:cta]))
end

length(caa4_constraint_capacity) > 0 && logmsg("Created constraint CAa4_Constraint_Capacity.", quiet)
# END: CAa4_Constraint_Capacity.

# BEGIN: CAa4Tr_Constraint_Capacity.
if transmissionmodeling
    caa4tr_constraint_capacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db,"select ntc.n as n, ntc.t as t, l.val as l, ntc.y as y, n.r as r,
    	cast(ntc.val as real) as ntc, cast(cf.val as real) as cf,
    	cast(cta.val as real) as cta
    from NodalDistributionTechnologyCapacity_def ntc, TIMESLICE l, NODE n,
    CapacityFactor_def cf, CapacityToActivityUnit_def cta
    where ntc.val > 0
    and ntc.n = n.val
    and cf.r = n.r and cf.t = ntc.t and cf.l = l.val and cf.y = ntc.y
    and cta.r = n.r and cta.t = ntc.t")
        local n = row[:n]
        local t = row[:t]
        local l = row[:l]
        local y = row[:y]
        local r = row[:r]

        push!(caa4tr_constraint_capacity, @constraint(jumpmodel, vrateoftotalactivitynodal[n,t,l,y]
            <= vtotalcapacityannual[r,t,y] * row[:ntc] * row[:cf] * row[:cta]))
    end

    length(caa4tr_constraint_capacity) > 0 && logmsg("Created constraint CAa4Tr_Constraint_Capacity.", quiet)
end
# END: CAa4Tr_Constraint_Capacity.

# BEGIN: CAa5_TotalNewCapacity.
caa5_totalnewcapacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db,"select cot.r as r, cot.t as t, cot.y as y, cast(cot.val as real) as cot
from CapacityOfOneTechnologyUnit_def cot where cot.val <> 0")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(caa5_totalnewcapacity, @constraint(jumpmodel, row[:cot] * vnumberofnewtechnologyunits[r,t,y]
        == vnewcapacity[r,t,y]))
end

length(caa5_totalnewcapacity) > 0 && logmsg("Created constraint CAa5_TotalNewCapacity.", quiet)
# END: CAa5_TotalNewCapacity.

#= BEGIN: CAb1_PlannedMaintenance.
# Omitting this constraint since it only serves to apply AvailabilityFactor, for which user demand isn't clear.
#   This parameter specifies an outage on an annual level and lets the model choose when (in which time slices) to take it.
#   Note that the parameter isn't used by LEAP. Omitting the constraint improves performance. If the constraint were
#   reinstated, a variant for transmission modeling (incorporating vrateoftotalactivitynodal) would be needed.
constraintnum = 1  # Number of next constraint to be added to constraint array
@constraintref cab1_plannedmaintenance[1:length(sregion) * length(stechnology) * length(syear)]

lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = y
lastvals = Array{Float64, 1}(undef,2)  # lastvals[1] = af, lastvals[2] = cta
sumexps = Array{AffExpr, 1}([AffExpr(), AffExpr()])
# sumexps[1] = vrateoftotalactivity sum, sumexps[2] vtotalcapacityannual sum

for row in DataFrames.eachrow(SQLite.query(db, "select r.val as r, t.val as t, y.val as y,
ys.l as l, cast(ys.val as real) as ys, cast(cf.val as real) as cf,
cast(af.val as real) as af, cast(cta.val as real) as cta
from REGION r, TECHNOLOGY t, YEAR y, YearSplit_def ys, CapacityFactor_def cf,
AvailabilityFactor_def af, CapacityToActivityUnit_def cta
where
ys.y = y.val
and cf.r = r.val and cf.t = t.val and cf.l = ys.l and cf.y = y.val
and af.r = r.val and af.t = t.val and af.y = y.val
and cta.r = r.val and cta.t = t.val
order by r.val, t.val, y.val"))
    local r = row[:r]
    local t = row[:t]
    local l = row[:l]
    local y = row[:y]
    local ys = row[:ys]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        cab1_plannedmaintenance[constraintnum] = @constraint(jumpmodel, sumexps[1] <= sumexps[2] * lastvals[1] * lastvals[2])
        constraintnum += 1

        sumexps[1] = AffExpr()
        sumexps[2] = AffExpr()
    end

    append!(sumexps[1], vrateoftotalactivity[r,t,l,y] * ys)
    append!(sumexps[2], vtotalcapacityannual[r,t,y] * row[:cf] * ys)

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = y
    lastvals[1] = row[:af]
    lastvals[2] = row[:cta]
end

# Create last constraint
if isassigned(lastkeys, 1)
    cab1_plannedmaintenance[constraintnum] = @constraint(jumpmodel, sumexps[1] <= sumexps[2] * lastvals[1] * lastvals[2])
end

logmsg("Created constraint CAb1_PlannedMaintenance.", quiet)
# END: CAb1_PlannedMaintenance. =#

# BEGIN: EBa1_RateOfFuelProduction1.
if in("vrateofproductionbytechnologybymodenn", varstosavearr)
    eba1_rateoffuelproduction1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in DataFrames.eachrow(queries["queryvrateofproductionbytechnologybymodenn"])
        local r = row[:r]
        local l = row[:l]
        local t = row[:t]
        local m = row[:m]
        local f = row[:f]
        local y = row[:y]

        push!(eba1_rateoffuelproduction1, @constraint(jumpmodel, vrateofactivity[r,l,t,m,y] * row[:oar] == vrateofproductionbytechnologybymodenn[r,l,t,m,f,y]))
    end

    length(eba1_rateoffuelproduction1) > 0 && logmsg("Created constraint EBa1_RateOfFuelProduction1.", quiet)
end  # in("vrateofproductionbytechnologybymodenn", varstosavearr)
# END: EBa1_RateOfFuelProduction1.

# BEGIN: EBa2_RateOfFuelProduction2.
eba2_rateoffuelproduction2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
sumexps = Array{AffExpr, 1}([AffExpr()])
# sumexps[1] = vrateofproductionbytechnologybymodenn-equivalent sum

for row in DataFrames.eachrow(queries["queryvrateofproductionbytechnologybymodenn"])
    local r = row[:r]
    local l = row[:l]
    local t = row[:t]
    local f = row[:f]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
        # Create constraint
        push!(eba2_rateoffuelproduction2, @constraint(jumpmodel, sumexps[1] ==
            vrateofproductionbytechnologynn[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivity[r,l,t,row[:m],y] * row[:oar])
    # Sum is of vrateofproductionbytechnologybymodenn[r,l,t,row[:m],f,y])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = t
    lastkeys[4] = f
    lastkeys[5] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(eba2_rateoffuelproduction2, @constraint(jumpmodel, sumexps[1] ==
        vrateofproductionbytechnologynn[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
end

length(eba2_rateoffuelproduction2) > 0 && logmsg("Created constraint EBa2_RateOfFuelProduction2.", quiet)
# END: EBa2_RateOfFuelProduction2.

# BEGIN: EBa2Tr_RateOfFuelProduction2.
if transmissionmodeling
    eba2tr_rateoffuelproduction2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = n, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])
    # sumexps[1] = vrateofactivitynodal sum

    for row in SQLite.DBInterface.execute(db,
    "select ntc.n as n, ys.l as l, ntc.t as t, oar.f as f, ntc.y as y, m.val as m,
	   cast(oar.val as real) as oar
    from NodalDistributionTechnologyCapacity_def ntc, YearSplit_def ys, MODE_OF_OPERATION m, NODE n, OutputActivityRatio_def oar,
	TransmissionModelingEnabled tme
    where ntc.val > 0
    and ntc.y = ys.y
    and ntc.n = n.val
    and oar.r = n.r and oar.t = ntc.t and oar.m = m.val and oar.y = ntc.y
    and oar.val > 0
	and tme.r = n.r and tme.f = oar.f and tme.y = ntc.y
    order by ntc.n, ys.l, ntc.t, oar.f, ntc.y")
        local n = row[:n]
        local l = row[:l]
        local t = row[:t]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
            # Create constraint
            push!(eba2tr_rateoffuelproduction2, @constraint(jumpmodel, sumexps[1] ==
                vrateofproductionbytechnologynodal[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofactivitynodal[n,l,t,row[:m],y] * row[:oar])

        lastkeys[1] = n
        lastkeys[2] = l
        lastkeys[3] = t
        lastkeys[4] = f
        lastkeys[5] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(eba2tr_rateoffuelproduction2, @constraint(jumpmodel, sumexps[1] ==
            vrateofproductionbytechnologynodal[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
    end

    length(eba2tr_rateoffuelproduction2) > 0 && logmsg("Created constraint EBa2Tr_RateOfFuelProduction2.", quiet)
end
# END: EBa2Tr_RateOfFuelProduction2.

# BEGIN: EBa3_RateOfFuelProduction3.
eba3_rateoffuelproduction3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofproductionbytechnologynn sum

# First step: define vrateofproductionnn where technologies exist
for row in DataFrames.eachrow(queries["queryvrateofproductionbytechnologynn"])
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(eba3_rateoffuelproduction3, @constraint(jumpmodel, sumexps[1] == vrateofproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofproductionbytechnologynn[r,l,row[:t],f,y])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = f
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(eba3_rateoffuelproduction3, @constraint(jumpmodel, sumexps[1] == vrateofproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

# Second step: define vrateofproductionnn where technologies don't exist
for row in SQLite.DBInterface.execute(db, "select r.val as r, l.val as l, f.val as f, y.val as y
from region r, TIMESLICE l, fuel f, year y
left join TransmissionModelingEnabled tme on tme.r = r.val and tme.f = f.val and tme.y = y.val
left join (select distinct r, t, f, y from OutputActivityRatio_def where val <> 0) oar
	on oar.r = r.val and oar.f = f.val and oar.y = y.val
where tme.id is null
and oar.t is null")

    push!(eba3_rateoffuelproduction3, @constraint(jumpmodel, 0 == vrateofproductionnn[row[:r],row[:l],row[:f],row[:y]]))
end

length(eba3_rateoffuelproduction3) > 0 && logmsg("Created constraint EBa3_RateOfFuelProduction3.", quiet)
# END: EBa3_RateOfFuelProduction3.

# BEGIN: EBa3Tr_RateOfFuelProduction3.
if transmissionmodeling
    eba3tr_rateoffuelproduction3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofproductionbytechnologynodal sum

    # First step: set vrateofproductionnodal for nodes with technologies
    for row in DataFrames.eachrow(queries["queryvrateofproductionbytechnologynodal"])
        local n = row[:n]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(eba3tr_rateoffuelproduction3, @constraint(jumpmodel, sumexps[1] == vrateofproductionnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofproductionbytechnologynodal[n,l,row[:t],f,y])

        lastkeys[1] = n
        lastkeys[2] = l
        lastkeys[3] = f
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(eba3tr_rateoffuelproduction3, @constraint(jumpmodel, sumexps[1] == vrateofproductionnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end

    # Second step: set vrateofproductionnodal for nodes without technologies
    for row in SQLite.DBInterface.execute(db, "select n.val as n, l.val as l, f.val as f, y.val as y, ntc.t as t
        from node n, timeslice l, fuel f, year y, TransmissionModelingEnabled tme
        left join NodalDistributionTechnologyCapacity_def ntc on ntc.n = n.val and ntc.y = y.val and ntc.val > 0
        where n.r = tme.r
        and f.val = tme.f
        and y.val = tme.y
        and ntc.t is null")

        push!(eba3tr_rateoffuelproduction3, @constraint(jumpmodel, 0 == vrateofproductionnodal[row[:n],row[:l],row[:f],row[:y]]))
    end

    length(eba3tr_rateoffuelproduction3) > 0 && logmsg("Created constraint EBa3Tr_RateOfFuelProduction3.", quiet)
end
# END: EBa3Tr_RateOfFuelProduction3.

# BEGIN: VRateOfProduction1.
queryvrateofproduse::SQLite.Query = SQLite.DBInterface.execute(db, "select 1")  # Populated below if transmissionmodeling
vrateofproduction1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

if !transmissionmodeling
    for (r, l, f, y) in Base.product(sregion, stimeslice, sfuel, syear)
        push!(vrateofproduction1, @constraint(jumpmodel, vrateofproduction[r,l,f,y] == vrateofproductionnn[r,l,f,y]))
    end
else
    # Combine nodal and non-nodal
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofproductionnodal sum

    queryvrateofproduse = SQLite.DBInterface.execute(db,
    "select r.val as r, l.val as l, f.val as f, y.val as y, tme.id as tme, n.val as n
    from region r, timeslice l, fuel f, year y, YearSplit_def ys
    left join TransmissionModelingEnabled tme on tme.r = r.val and tme.f = f.val and tme.y = y.val
    left join NODE n on n.r = r.val
    where
    ys.l = l.val and ys.y = y.val
    order by r.val, l.val, f.val, y.val")

    for row in queryvrateofproduse
        local r = row[:r]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(vrateofproduction1, @constraint(jumpmodel,
                (sumexps[1] == AffExpr() ? vrateofproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] : sumexps[1])
                == vrateofproduction[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        if !ismissing(row[:tme]) && !ismissing(row[:n])
            append!(sumexps[1], vrateofproductionnodal[row[:n],l,f,y])
        end

        lastkeys[1] = r
        lastkeys[2] = l
        lastkeys[3] = f
        lastkeys[4] = y
    end

    SQLite.reset!(queryvrateofproduse)

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(vrateofproduction1, @constraint(jumpmodel,
            (sumexps[1] == AffExpr() ? vrateofproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] : sumexps[1])
            == vrateofproduction[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end
end

length(vrateofproduction1) > 0 && logmsg("Created constraint VRateOfProduction1.", quiet)
# END: VRateOfProduction1.

# BEGIN: EBa4_RateOfFuelUse1.
if in("vrateofusebytechnologybymodenn", varstosavearr)
    eba4_rateoffueluse1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in DataFrames.eachrow(queries["queryvrateofusebytechnologybymodenn"])
        local r = row[:r]
        local l = row[:l]
        local f = row[:f]
        local t = row[:t]
        local m = row[:m]
        local y = row[:y]

        push!(eba4_rateoffueluse1, @constraint(jumpmodel, vrateofactivity[r,l,t,m,y] * row[:iar] == vrateofusebytechnologybymodenn[r,l,t,m,f,y]))
    end

    length(eba4_rateoffueluse1) > 0 && logmsg("Created constraint EBa4_RateOfFuelUse1.", quiet)
end
# END: EBa4_RateOfFuelUse1.

# BEGIN: EBa5_RateOfFuelUse2.
eba5_rateoffueluse2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
sumexps = Array{AffExpr, 1}([AffExpr()]) # sumexps[1] = vrateofusebytechnologybymodenn-equivalent sum

for row in DataFrames.eachrow(queries["queryvrateofusebytechnologybymodenn"])
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local t = row[:t]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
        # Create constraint
        push!(eba5_rateoffueluse2, @constraint(jumpmodel, sumexps[1] ==
            vrateofusebytechnologynn[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivity[r,l,t,row[:m],y] * row[:iar])
    # Sum is of vrateofusebytechnologybymodenn[r,l,t,row[:m],f,y])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = t
    lastkeys[4] = f
    lastkeys[5] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(eba5_rateoffueluse2, @constraint(jumpmodel, sumexps[1] ==
        vrateofusebytechnologynn[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
end

length(eba5_rateoffueluse2) > 0 && logmsg("Created constraint EBa5_RateOfFuelUse2.", quiet)
# END: EBa5_RateOfFuelUse2.

# BEGIN: EBa5Tr_RateOfFuelUse2.
if transmissionmodeling
    eba5tr_rateoffueluse2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = n, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivitynodal sum

    for row in SQLite.DBInterface.execute(db,
    "select ntc.n as n, ys.l as l, ntc.t as t, iar.f as f, ntc.y as y, m.val as m,
	   cast(iar.val as real) as iar
    from NodalDistributionTechnologyCapacity_def ntc, YearSplit_def ys, MODE_OF_OPERATION m, NODE n, InputActivityRatio_def iar,
	TransmissionModelingEnabled tme
    where ntc.val > 0
    and ntc.y = ys.y
    and ntc.n = n.val
    and iar.r = n.r and iar.t = ntc.t and iar.m = m.val and iar.y = ntc.y
    and iar.val > 0
	and tme.r = n.r and tme.f = iar.f and tme.y = ntc.y
    order by ntc.n, ys.l, ntc.t, iar.f, ntc.y")
        local n = row[:n]
        local l = row[:l]
        local t = row[:t]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
            # Create constraint
            push!(eba5tr_rateoffueluse2, @constraint(jumpmodel, sumexps[1] ==
                vrateofusebytechnologynodal[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofactivitynodal[n,l,t,row[:m],y] * row[:iar])

        lastkeys[1] = n
        lastkeys[2] = l
        lastkeys[3] = t
        lastkeys[4] = f
        lastkeys[5] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(eba5tr_rateoffueluse2, @constraint(jumpmodel, sumexps[1] ==
            vrateofusebytechnologynodal[lastkeys[1], lastkeys[2], lastkeys[3], lastkeys[4], lastkeys[5]]))
    end

    length(eba5tr_rateoffueluse2) > 0 && logmsg("Created constraint EBa5Tr_RateOfFuelUse2.", quiet)
end
# END: EBa5Tr_RateOfFuelUse2.

# BEGIN: EBa6_RateOfFuelUse3.
eba6_rateoffueluse3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofusebytechnologynn sum

for row in DataFrames.eachrow(queries["queryvrateofusebytechnologynn"])
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(eba6_rateoffueluse3, @constraint(jumpmodel, sumexps[1] == vrateofusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofusebytechnologynn[r,l,row[:t],f,y])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = f
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(eba6_rateoffueluse3, @constraint(jumpmodel, sumexps[1] == vrateofusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(eba6_rateoffueluse3) > 0 && logmsg("Created constraint EBa6_RateOfFuelUse3.", quiet)
# END: EBa6_RateOfFuelUse3.

# BEGIN: EBa6Tr_RateOfFuelUse3.
if transmissionmodeling
    eba6tr_rateoffueluse3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofusebytechnologynodal sum

    for row in DataFrames.eachrow(queries["queryvrateofusebytechnologynodal"])
        local n = row[:n]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(eba6tr_rateoffueluse3, @constraint(jumpmodel, sumexps[1] == vrateofusenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofusebytechnologynodal[n,l,row[:t],f,y])

        lastkeys[1] = n
        lastkeys[2] = l
        lastkeys[3] = f
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(eba6tr_rateoffueluse3, @constraint(jumpmodel, sumexps[1] == vrateofusenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end

    length(eba6tr_rateoffueluse3) > 0 && logmsg("Created constraint EBa6Tr_RateOfFuelUse3.", quiet)
end
# END: EBa6Tr_RateOfFuelUse3.

# BEGIN: VRateOfUse1.
vrateofuse1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

if !transmissionmodeling
    for (r, l, f, y) in Base.product(sregion, stimeslice, sfuel, syear)
        push!(vrateofuse1, @constraint(jumpmodel, vrateofuse[r,l,f,y] == vrateofusenn[r,l,f,y]))
    end
else
    # Combine nodal and non-nodal
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofusenodal sum

    for row in queryvrateofproduse
        local r = row[:r]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(vrateofuse1, @constraint(jumpmodel,
                (sumexps[1] == AffExpr() ? vrateofusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] : sumexps[1])
                == vrateofuse[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        if !ismissing(row[:tme]) && !ismissing(row[:n])
            append!(sumexps[1], vrateofusenodal[row[:n],l,f,y])
        end

        lastkeys[1] = r
        lastkeys[2] = l
        lastkeys[3] = f
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(vrateofuse1, @constraint(jumpmodel,
            (sumexps[1] == AffExpr() ? vrateofusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] : sumexps[1])
            == vrateofuse[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end
end

length(vrateofuse1) > 0 && logmsg("Created constraint VRateOfUse1.", quiet)
# END: VRateOfUse1.

# BEGIN: EBa7_EnergyBalanceEachTS1 and EBa8_EnergyBalanceEachTS2.
queryvproduse::SQLite.Query = SQLite.DBInterface.execute(db, "select r.val as r, l.val as l, f.val as f, y.val as y, cast(ys.val as real) as ys
from region r, timeslice l, fuel f, year y, YearSplit_def ys
left join TransmissionModelingEnabled tme on tme.r = r.val and tme.f = f.val and tme.y = y.val
where
ys.l = l.val and ys.y = y.val
and tme.id is null")

eba7_energybalanceeachts1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
eba8_energybalanceeachts2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryvproduse
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local y = row[:y]

    push!(eba7_energybalanceeachts1, @constraint(jumpmodel, vrateofproductionnn[r,l,f,y] * row[:ys] == vproductionnn[r,l,f,y]))
    push!(eba8_energybalanceeachts2, @constraint(jumpmodel, vrateofusenn[r,l,f,y] * row[:ys] == vusenn[r,l,f,y]))
end

length(eba7_energybalanceeachts1) > 0 && logmsg("Created constraint EBa7_EnergyBalanceEachTS1.", quiet)
length(eba8_energybalanceeachts2) > 0 && logmsg("Created constraint EBa8_EnergyBalanceEachTS2.", quiet)
# END: EBa7_EnergyBalanceEachTS1 and EBa8_EnergyBalanceEachTS2.

# BEGIN: EBa7Tr_EnergyBalanceEachTS1 and EBa8Tr_EnergyBalanceEachTS2.
if transmissionmodeling
    queryvproduse = SQLite.DBInterface.execute(db, "select n.val as n, l.val as l, f.val as f, y.val as y, cast(ys.val as real) as ys
    from node n, timeslice l, fuel f, year y, YearSplit_def ys,
    TransmissionModelingEnabled tme
    where
    ys.l = l.val and ys.y = y.val
    and tme.r = n.r and tme.f = f.val and tme.y = y.val")

    eba7tr_energybalanceeachts1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    eba8tr_energybalanceeachts2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in queryvproduse
        local n = row[:n]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        push!(eba7tr_energybalanceeachts1, @constraint(jumpmodel, vrateofproductionnodal[n,l,f,y] * row[:ys] == vproductionnodal[n,l,f,y]))
        push!(eba8tr_energybalanceeachts2, @constraint(jumpmodel, vrateofusenodal[n,l,f,y] * row[:ys] == vusenodal[n,l,f,y]))
    end

    length(eba7tr_energybalanceeachts1) > 0 && logmsg("Created constraint EBa7Tr_EnergyBalanceEachTS1.", quiet)
    length(eba8tr_energybalanceeachts2) > 0 && logmsg("Created constraint EBa8Tr_EnergyBalanceEachTS2.", quiet)
end
# END: EBa7Tr_EnergyBalanceEachTS1 and EBa8Tr_EnergyBalanceEachTS2.

# BEGIN: EBa9_EnergyBalanceEachTS3.
eba9_energybalanceeachts3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryvrateofdemandnn
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local y = row[:y]

    push!(eba9_energybalanceeachts3, @constraint(jumpmodel, row[:specifiedannualdemand] * row[:specifieddemandprofile] == vdemandnn[r,l,f,y]))
end

length(eba9_energybalanceeachts3) > 0 && logmsg("Created constraint EBa9_EnergyBalanceEachTS3.", quiet)
# END: EBa9_EnergyBalanceEachTS3.

# BEGIN: EBa9Tr_EnergyBalanceEachTS3.
if transmissionmodeling
    eba9tr_energybalanceeachts3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select sdp.r as r, sdp.f as f, sdp.l as l, sdp.y as y, ndd.n as n,
    cast(sdp.val as real) as specifieddemandprofile, cast(sad.val as real) as specifiedannualdemand,
    cast(ndd.val as real) as ndd
    from SpecifiedDemandProfile_def sdp, SpecifiedAnnualDemand_def sad, TransmissionModelingEnabled tme,
    NodalDistributionDemand_def ndd, NODE n
    where sad.r = sdp.r and sad.f = sdp.f and sad.y = sdp.y
    and sdp.val <> 0 and sad.val <> 0
    and tme.r = sad.r and tme.f = sad.f and tme.y = sad.y
    and ndd.n = n.val
    and n.r = sad.r and ndd.f = sad.f and ndd.y = sad.y
    and ndd.val > 0")
        local n = row[:n]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]

        push!(eba9tr_energybalanceeachts3, @constraint(jumpmodel, row[:specifiedannualdemand] * row[:specifieddemandprofile]
            * row[:ndd] == vdemandnodal[n,l,f,y]))
    end

    length(eba9tr_energybalanceeachts3) > 0 && logmsg("Created constraint EBa9Tr_EnergyBalanceEachTS3.", quiet)
end
# END: EBa9Tr_EnergyBalanceEachTS3.

# BEGIN: EBa10_EnergyBalanceEachTS4.
eba10_energybalanceeachts4::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, rr, l, f, y) in Base.product(sregion, sregion, stimeslice, sfuel, syear)
    push!(eba10_energybalanceeachts4, @constraint(jumpmodel, vtrade[r,rr,l,f,y] == -vtrade[rr,r,l,f,y]))
end

length(eba10_energybalanceeachts4) > 0 && logmsg("Created constraint EBa10_EnergyBalanceEachTS4.", quiet)
# END: EBa10_EnergyBalanceEachTS4.

# BEGIN: EBa11_EnergyBalanceEachTS5.
eba11_energybalanceeachts5::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])
# sumexps[1] = vtrade sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, l.val as l, f.val as f, y.val as y, tr.rr as rr,
    cast(tr.val as real) as trv
from region r, timeslice l, fuel f, year y
left join traderoute_def tr on tr.r = r.val and tr.f = f.val and tr.y = y.val
left join TransmissionModelingEnabled tme on tme.r = r.val and tme.f = f.val and tme.y = y.val
where tme.id is null
order by r.val, l.val, f.val, y.val")
    local r = row[:r]
    local l = row[:l]
    local f = row[:f]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(eba11_energybalanceeachts5, @constraint(jumpmodel, vproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] >=
            vdemandnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + vusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + sumexps[1]))
        sumexps[1] = AffExpr()
    end

    # Appears that traderoutes must be defined reciprocally - two entries for each pair of regions. Bears testing.
    if !ismissing(row[:rr])
        append!(sumexps[1], vtrade[r,row[:rr],l,f,y] * row[:trv])
    end

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = f
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(eba11_energybalanceeachts5, @constraint(jumpmodel, vproductionnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] >=
        vdemandnn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + vusenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + sumexps[1]))
end

length(eba11_energybalanceeachts5) > 0 && logmsg("Created constraint EBa11_EnergyBalanceEachTS5.", quiet)
# END: EBa11_EnergyBalanceEachTS5.

# BEGIN: Tr1_SumBuilt.
# Ensures vtransmissionbuilt can be 1 in at most one year
if transmissionmodeling
    tr1_sumbuilt::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for tr in stransmission
        push!(tr1_sumbuilt, @constraint(jumpmodel, sum([vtransmissionbuilt[tr,y] for y in syear]) <= 1))
    end

    length(tr1_sumbuilt) > 0 && logmsg("Created constraint Tr1_SumBuilt.", quiet)
end
# END: Tr1_SumBuilt.

# BEGIN: Tr2_TransmissionExists.
if transmissionmodeling
    tr2_transmissionexists::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,2)  # lastkeys[1] = tr, lastkeys[2] = y
    lastvalsint = Array{Int64, 1}(undef,2)  # lastvalsint[1] = yconstruction, lastvalsint[2] = operationallife
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vtransmissionbuilt sum

    for row in SQLite.DBInterface.execute(db, "select tl.id as tr, tl.yconstruction, tl.operationallife, y.val as y, null as yy
    from TransmissionLine tl, YEAR y
    where tl.yconstruction is not null
    union all
    select tl.id as tr, tl.yconstruction, tl.operationallife, y.val as y, yy.val as yy
    from TransmissionLine tl, YEAR y, YEAR yy
    where tl.yconstruction is null
    and yy.val + tl.operationallife > y.val
    and yy.val <= y.val
    order by tr, y")
        local tr = row[:tr]
        local y = row[:y]
        local yy = row[:yy]
        local yconstruction = ismissing(row[:yconstruction]) ? 0 : row[:yconstruction]

        if isassigned(lastkeys, 1) && (tr != lastkeys[1] || y != lastkeys[2])
            # Create constraint
            if sumexps[1] == AffExpr()
                # Exogenously built line
                if (lastvalsint[1] <= Meta.parse(lastkeys[2])) && (lastvalsint[1] + lastvalsint[2] > Meta.parse(lastkeys[2]))
                    push!(tr2_transmissionexists, @constraint(jumpmodel, vtransmissionexists[lastkeys[1],lastkeys[2]] == 1))
                else
                    push!(tr2_transmissionexists, @constraint(jumpmodel, vtransmissionexists[lastkeys[1],lastkeys[2]] == 0))
                end
            else
                # Endogenous option
                push!(tr2_transmissionexists, @constraint(jumpmodel, sumexps[1] == vtransmissionexists[lastkeys[1],lastkeys[2]]))
            end

            sumexps[1] = AffExpr()
        end

        if !ismissing(yy)
            append!(sumexps[1], vtransmissionbuilt[tr,yy])
        end

        lastkeys[1] = tr
        lastkeys[2] = y
        lastvalsint[1] = yconstruction
        lastvalsint[2] = row[:operationallife]
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        if sumexps[1] == AffExpr()
            # Exogenously built line
            if (lastvalsint[1] <= Meta.parse(lastkeys[2])) && (lastvalsint[1] + lastvalsint[2] > Meta.parse(lastkeys[2]))
                push!(tr2_transmissionexists, @constraint(jumpmodel, vtransmissionexists[lastkeys[1],lastkeys[2]] == 1))
            else
                push!(tr2_transmissionexists, @constraint(jumpmodel, vtransmissionexists[lastkeys[1],lastkeys[2]] == 0))
            end
        else
            # Endogenous option
            push!(tr2_transmissionexists, @constraint(jumpmodel, sumexps[1] == vtransmissionexists[lastkeys[1],lastkeys[2]]))
        end
    end

    length(tr2_transmissionexists) > 0 && logmsg("Created constraint Tr2_TransmissionExists.", quiet)
end
# END: Tr2_TransmissionExists.

# BEGIN: Tr3_Flow, Tr4_MaxFlow, and Tr5_MinFlow.
if transmissionmodeling
    tr3_flow::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    tr3a_flow::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    tr4_maxflow::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    tr5_minflow::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in DataFrames.eachrow(queries["queryvtransmissionbyline"])
        local tr = row[:tr]
        local n1 = row[:n1]
        local n2 = row[:n2]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]
        local type = row[:type]

        # vtransmissionbyline is flow over line tr from n1 to n2; unit is MW
        if type == 1  # DCOPF
            push!(tr3_flow, @constraint(jumpmodel, 1/row[:reactance] * (vvoltageangle[n1,l,y] - vvoltageangle[n2,l,y]) * vtransmissionexists[tr,y]
                == vtransmissionbyline[tr,l,f,y]))
            push!(tr4_maxflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] <= row[:maxflow]))
            push!(tr5_minflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] >= -row[:maxflow]))
        elseif type == 2  # DCOPF with disjunctive formulation
            push!(tr3_flow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] -
                (1/row[:reactance] * (vvoltageangle[n1,l,y] - vvoltageangle[n2,l,y]))
                <= (1 - vtransmissionexists[tr,y]) * 500000))
            push!(tr3a_flow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] -
                (1/row[:reactance] * (vvoltageangle[n1,l,y] - vvoltageangle[n2,l,y]))
                >= (vtransmissionexists[tr,y] - 1) * 500000))
            #tr4_maxflow[constraintnum] = @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y]^2 <= vtransmissionexists[tr,y] * row[:maxflow]^2)
            #tr5_minflow[constraintnum] = @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y]^2 >= 0)
            push!(tr4_maxflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] <= vtransmissionexists[tr,y] * row[:maxflow]))
            push!(tr5_minflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] >= -vtransmissionexists[tr,y] * row[:maxflow]))
        elseif type == 3  # Pipeline flow
            push!(tr4_maxflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] <= vtransmissionexists[tr,y] * row[:maxflow]))
            push!(tr5_minflow, @constraint(jumpmodel, vtransmissionbyline[tr,l,f,y] >= -vtransmissionexists[tr,y] * row[:maxflow]))
        end
    end

    length(tr3_flow) > 0 && logmsg("Created constraint Tr3_Flow.", quiet)
    length(tr4_maxflow) > 0 && logmsg("Created constraint Tr4_MaxFlow.", quiet)
    length(tr5_minflow) > 0 && logmsg("Created constraint Tr5_MinFlow.", quiet)
end
# END: Tr3_Flow, Tr4_MaxFlow, and Tr5_MinFlow.

# BEGIN: EBa11Tr_EnergyBalanceEachTS5 and EBb4_EnergyBalanceEachYear.
if transmissionmodeling
    eba11tr_energybalanceeachts5::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ebb4_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = l, lastkeys[3] = f, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr(), AffExpr()])  # sumexps[1] = vtransmissionbyline sum for eba11tr_energybalanceeachts5 (aggregated by node),
        # sumexps[2] = vtransmissionbyline sum for ebb4_energybalanceeachyear (aggregated by node and timeslice)

    # First query selects transmission-enabled nodes without any transmission lines, second selects transmission-enabled
    #   nodes that are n1 in a valid transmission line, third selects transmission-enabled nodes that are n2 in a
    #   valid transmission line
    for row in SQLite.DBInterface.execute(db, "select n.val as n, ys.l as l, f.val as f, y.val as y,
    cast(ys.val as real) as ys, null as tr, null as n2, null as trneg, null as n1,
	null as eff, tme.type as type, cast(tcta.val as real) as tcta
    from NODE n, YearSplit_def ys, FUEL f, YEAR y, TransmissionModelingEnabled tme,
	TransmissionCapacityToActivityUnit_def tcta
	where ys.y = y.val
    and tme.r = n.r and tme.f = f.val and tme.y = y.val
	and tcta.f = f.val
	and not exists (select 1 from TransmissionLine tl, NODE n2, TransmissionModelingEnabled tme2
	where
	n.val = tl.n1 and f.val = tl.f
	and tl.n2 = n2.val
	and n2.r = tme2.r and tl.f = tme2.f and y.val = tme2.y and tme.type = tme2.type)
	and not exists (select 1 from TransmissionLine tl, NODE n2, TransmissionModelingEnabled tme2
	where
	n.val = tl.n2 and f.val = tl.f
	and tl.n1 = n2.val
	and n2.r = tme2.r and tl.f = tme2.f and y.val = tme2.y and tme.type = tme2.type)
union all
select n.val as n, ys.l as l, f.val as f, y.val as y,
    cast(ys.val as real) as ys, tl.id as tr, tl.n2 as n2, null as trneg, null as n1, null as eff, tme.type as type,
	cast(tcta.val as real) as tcta
    from NODE n, YearSplit_def ys, FUEL f, YEAR y, TransmissionModelingEnabled tme,
	TransmissionLine tl, NODE n2, TransmissionModelingEnabled tme2, TransmissionCapacityToActivityUnit_def tcta
	where ys.y = y.val
    and tme.r = n.r and tme.f = f.val and tme.y = y.val
	and tcta.f = f.val
	and n.val = tl.n1 and f.val = tl.f
	and tl.n2 = n2.val
	and n2.r = tme2.r and tl.f = tme2.f and y.val = tme2.y and tme.type = tme2.type
union all
select n.val as n, ys.l as l, f.val as f, y.val as y,
    cast(ys.val as real) as ys, null as tr, null as n2, tl.id as trneg, tl.n1 as n1,
	cast(tl.efficiency as real) as eff, tme.type as type,
	cast(tcta.val as real) as tcta
    from NODE n, YearSplit_def ys, FUEL f, YEAR y, TransmissionModelingEnabled tme,
	TransmissionLine tl, NODE n2, TransmissionModelingEnabled tme2, TransmissionCapacityToActivityUnit_def tcta
	where ys.y = y.val
    and tme.r = n.r and tme.f = f.val and tme.y = y.val
	and tcta.f = f.val
	and n.val = tl.n2 and f.val = tl.f
	and tl.n1 = n2.val
	and n2.r = tme2.r and tl.f = tme2.f and y.val = tme2.y and tme.type = tme2.type
order by n, f, y, l")
        local n = row[:n]
        local l = row[:l]
        local f = row[:f]
        local y = row[:y]
        local tr = row[:tr]  # Transmission line for which n is from node (n1)
        local trneg = row[:trneg]  # Transmission line for which n is to node (n2)
        local eff = ismissing(row[:eff]) ? 1.0 : row[:eff]
        local trtype = row[:type]  # Type of transmission modeling for node

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || l != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            # May want to change this to an equality constraint
            push!(eba11tr_energybalanceeachts5, @constraint(jumpmodel, vproductionnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] >=
                vdemandnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + vusenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + sumexps[1]))
            sumexps[1] = AffExpr()
        end

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || f != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            # vtransmissionannual is net annual transmission from n in energy terms
            push!(ebb4_energybalanceeachyear, @constraint(jumpmodel, vtransmissionannual[lastkeys[1],lastkeys[3],lastkeys[4]] == sumexps[2]))
            sumexps[2] = AffExpr()
        end

        if !ismissing(tr)
            if trtype == 1 || trtype == 2 || trtype == 3
                append!(sumexps[1], vtransmissionbyline[tr,l,f,y] * row[:ys] * row[:tcta])
                append!(sumexps[2], vtransmissionbyline[tr,l,f,y] * row[:ys] * row[:tcta])
            end
        end

        if !ismissing(trneg)
            if trtype == 1 || trtype == 2
                append!(sumexps[1], -vtransmissionbyline[trneg,l,f,y] * row[:ys] * row[:tcta])
                append!(sumexps[2], -vtransmissionbyline[trneg,l,f,y] * row[:ys] * row[:tcta])
            elseif trtype == 3  # Incorporate efficiency for to node in pipeline flow
                append!(sumexps[1], -vtransmissionbyline[trneg,l,f,y] * row[:ys] * row[:tcta] * eff)
                append!(sumexps[2], -vtransmissionbyline[trneg,l,f,y] * row[:ys] * row[:tcta] * eff)
            end
        end

        lastkeys[1] = n
        lastkeys[2] = l
        lastkeys[3] = f
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(eba11tr_energybalanceeachts5, @constraint(jumpmodel, vproductionnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] >=
            vdemandnodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + vusenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]] + sumexps[1]))
        push!(ebb4_energybalanceeachyear, @constraint(jumpmodel, vtransmissionannual[lastkeys[1],lastkeys[3],lastkeys[4]] == sumexps[2]))
    end

    length(eba11tr_energybalanceeachts5) > 0 && logmsg("Created constraint EBa11Tr_EnergyBalanceEachTS5.", quiet)
    length(ebb4_energybalanceeachyear) > 0 && logmsg("Created constraint EBb4_EnergyBalanceEachYear.", quiet)
end
# END: EBa11Tr_EnergyBalanceEachTS5 and EBb4_EnergyBalanceEachYear.

# BEGIN: EBb0_EnergyBalanceEachYear.
ebb0_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, f, y) in Base.product(sregion, sfuel, syear)
    push!(ebb0_energybalanceeachyear, @constraint(jumpmodel, sum([vdemandnn[r,l,f,y] for l = stimeslice]) == vdemandannualnn[r,f,y]))
end

length(ebb0_energybalanceeachyear) > 0 && logmsg("Created constraint EBb0_EnergyBalanceEachYear.", quiet)
# END: EBb0_EnergyBalanceEachYear.

# BEGIN: EBb0Tr_EnergyBalanceEachYear.
if transmissionmodeling
    ebb0tr_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for (n, f, y) in Base.product(snode, sfuel, syear)
        push!(ebb0tr_energybalanceeachyear, @constraint(jumpmodel, sum([vdemandnodal[n,l,f,y] for l = stimeslice]) == vdemandannualnodal[n,f,y]))
    end

    length(ebb0tr_energybalanceeachyear) > 0 && logmsg("Created constraint EBb0Tr_EnergyBalanceEachYear.", quiet)
end
# END: EBb0Tr_EnergyBalanceEachYear.

# BEGIN: EBb1_EnergyBalanceEachYear.
ebb1_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, f, y) in Base.product(sregion, sfuel, syear)
    push!(ebb1_energybalanceeachyear, @constraint(jumpmodel, sum([vproductionnn[r,l,f,y] for l = stimeslice]) == vproductionannualnn[r,f,y]))
end

length(ebb1_energybalanceeachyear) > 0 && logmsg("Created constraint EBb1_EnergyBalanceEachYear.", quiet)
# END: EBb1_EnergyBalanceEachYear.

# BEGIN: EBb1Tr_EnergyBalanceEachYear.
if transmissionmodeling
    ebb1tr_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for (n, f, y) in Base.product(snode, sfuel, syear)
        push!(ebb1tr_energybalanceeachyear, @constraint(jumpmodel, sum([vproductionnodal[n,l,f,y] for l = stimeslice]) == vproductionannualnodal[n,f,y]))
    end

    length(ebb1tr_energybalanceeachyear) > 0 && logmsg("Created constraint EBb1Tr_EnergyBalanceEachYear.", quiet)
end
# END: EBb1Tr_EnergyBalanceEachYear.

# BEGIN: EBb2_EnergyBalanceEachYear.
ebb2_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, f, y) in Base.product(sregion, sfuel, syear)
    push!(ebb2_energybalanceeachyear, @constraint(jumpmodel, sum([vusenn[r,l,f,y] for l = stimeslice]) == vuseannualnn[r,f,y]))
end

length(ebb2_energybalanceeachyear) > 0 && logmsg("Created constraint EBb2_EnergyBalanceEachYear.", quiet)
# END: EBb2_EnergyBalanceEachYear.

# BEGIN: EBb2Tr_EnergyBalanceEachYear.
if transmissionmodeling
    ebb2tr_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for (n, f, y) in Base.product(snode, sfuel, syear)
        push!(ebb2tr_energybalanceeachyear, @constraint(jumpmodel, sum([vusenodal[n,l,f,y] for l = stimeslice]) == vuseannualnodal[n,f,y]))
    end

    length(ebb2tr_energybalanceeachyear) > 0 && logmsg("Created constraint EBb2Tr_EnergyBalanceEachYear.", quiet)
end
# END: EBb2Tr_EnergyBalanceEachYear.

# BEGIN: EBb3_EnergyBalanceEachYear.
ebb3_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, rr, f, y) in Base.product(sregion, sregion, sfuel, syear)
    push!(ebb3_energybalanceeachyear, @constraint(jumpmodel, sum([vtrade[r,rr,l,f,y] for l = stimeslice]) == vtradeannual[r,rr,f,y]))
end

length(ebb3_energybalanceeachyear) > 0 && logmsg("Created constraint EBb3_EnergyBalanceEachYear.", quiet)
# END: EBb3_EnergyBalanceEachYear.

# BEGIN: EBb5_EnergyBalanceEachYear.
ebb5_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = f, lastkeys[3] = y
lastvals = Array{Float64, 1}([0.0])  # lastvals[1] = aad
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vtradeannual sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, f.val as f, y.val as y, cast(aad.val as real) as aad,
    tr.rr as rr, cast(tr.val as real) as trv
from region r, fuel f, year y
left join traderoute_def tr on tr.r = r.val and tr.f = f.val and tr.y = y.val
left join AccumulatedAnnualDemand_def aad on aad.r = r.val and aad.f = f.val and aad.y = y.val
left join TransmissionModelingEnabled tme on tme.r = r.val and tme.f = f.val and tme.y = y.val
where tme.id is null
order by r.val, f.val, y.val")
    local r = row[:r]
    local f = row[:f]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || f != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        # Inclusion of vdemandannualnn allows users to specify both timesliced and non-timesliced demands for a fuel
        push!(ebb5_energybalanceeachyear, @constraint(jumpmodel, vproductionannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] >=
            vdemandannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] + vuseannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] + sumexps[1] + lastvals[1]))
        sumexps[1] = AffExpr()
        lastvals[1] = 0.0
    end

    if !ismissing(row[:rr])
        append!(sumexps[1], vtradeannual[r,row[:rr],f,y] * row[:trv])
    end

    if !ismissing(row[:aad])
        lastvals[1] = row[:aad]
    end

    lastkeys[1] = r
    lastkeys[2] = f
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(ebb5_energybalanceeachyear, @constraint(jumpmodel, vproductionannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] >=
        vdemandannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] + vuseannualnn[lastkeys[1],lastkeys[2],lastkeys[3]] + sumexps[1] + lastvals[1]))
end

length(ebb5_energybalanceeachyear) > 0 && logmsg("Created constraint EBb5_EnergyBalanceEachYear.", quiet)
# END: EBb5_EnergyBalanceEachYear.

# BEGIN: EBb5Tr_EnergyBalanceEachYear.
# For nodal modeling, where there is no trade, this constraint accounts for AccumulatedAnnualDemand only.
if transmissionmodeling
    ebb5tr_energybalanceeachyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db,
        "select ndd.n as n, ndd.f as f, ndd.y as y, cast(ndd.val as real) as ndd, cast(aad.val as real) as aad
        from NodalDistributionDemand_def ndd, NODE n, TransmissionModelingEnabled tme, AccumulatedAnnualDemand_def aad
        where
        ndd.n = n.val
        and tme.r = n.r and tme.f = ndd.f and tme.y = ndd.y
        and aad.r = n.r and aad.f = ndd.f and aad.y = ndd.y
        and aad.val > 0")
        local n = row[:n]
        local f = row[:f]
        local y = row[:y]

        push!(ebb5tr_energybalanceeachyear, @constraint(jumpmodel, vproductionannualnodal[n,f,y] >=
            vdemandannualnodal[n,f,y] + vuseannualnodal[n,f,y] + vtransmissionannual[n,f,y] + row[:aad] * row[:ndd]))
    end

    length(ebb5tr_energybalanceeachyear) > 0 && logmsg("Created constraint EBb5Tr_EnergyBalanceEachYear.", quiet)
end
# END: EBb5Tr_EnergyBalanceEachYear.

# BEGIN: Acc1_FuelProductionByTechnology.
if in("vproductionbytechnology", varstosavearr)
    acc1_fuelproductionbytechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in DataFrames.eachrow(queries["queryvrateofproductionbytechnologynn"])
        local r = row[:r]
        local l = row[:l]
        local t = row[:t]
        local f = row[:f]
        local y = row[:y]

        push!(acc1_fuelproductionbytechnology, @constraint(jumpmodel, vrateofproductionbytechnologynn[r,l,t,f,y] * row[:ys] == vproductionbytechnology[r,l,t,f,y]))
    end

    if transmissionmodeling
        lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
        sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofproductionbytechnologynodal sum

        for row in queryvproductionbytechnologynodal
            local r = row[:r]
            local l = row[:l]
            local t = row[:t]
            local f = row[:f]
            local y = row[:y]

            if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
                # Create constraint
                push!(acc1_fuelproductionbytechnology, @constraint(jumpmodel, sumexps[1] ==
                    vproductionbytechnology[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
                sumexps[1] = AffExpr()
            end

            append!(sumexps[1], vrateofproductionbytechnologynodal[row[:n],l,t,f,y] * row[:ys])

            lastkeys[1] = r
            lastkeys[2] = l
            lastkeys[3] = t
            lastkeys[4] = f
            lastkeys[5] = y
        end

        # Create last constraint
        if isassigned(lastkeys, 1)
            push!(acc1_fuelproductionbytechnology, @constraint(jumpmodel, sumexps[1] ==
                vproductionbytechnology[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
        end
    end  # transmissionmodeling

    length(acc1_fuelproductionbytechnology) > 0 && logmsg("Created constraint Acc1_FuelProductionByTechnology.", quiet)
end  # in("vproductionbytechnology", varstosavearr)
# END: Acc1_FuelProductionByTechnology.

# BEGIN: Acc2_FuelUseByTechnology.
if in("vusebytechnology", varstosavearr)
    acc2_fuelusebytechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in DataFrames.eachrow(queries["queryvrateofusebytechnologynn"])
        local r = row[:r]
        local l = row[:l]
        local t = row[:t]
        local f = row[:f]
        local y = row[:y]

        push!(acc2_fuelusebytechnology, @constraint(jumpmodel, vrateofusebytechnologynn[r,l,t,f,y] * row[:ys] == vusebytechnology[r,l,t,f,y]))
    end

    if transmissionmodeling
        lastkeys = Array{String, 1}(undef,5)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = t, lastkeys[4] = f, lastkeys[5] = y
        sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofusebytechnologynodal sum

        for row in queryvusebytechnologynodal
            local r = row[:r]
            local l = row[:l]
            local t = row[:t]
            local f = row[:f]
            local y = row[:y]

            if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || t != lastkeys[3] || f != lastkeys[4] || y != lastkeys[5])
                # Create constraint
                push!(acc2_fuelusebytechnology, @constraint(jumpmodel, sumexps[1] ==
                    vusebytechnology[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
                sumexps[1] = AffExpr()
            end

            append!(sumexps[1], vrateofusebytechnologynodal[row[:n],l,t,f,y] * row[:ys])

            lastkeys[1] = r
            lastkeys[2] = l
            lastkeys[3] = t
            lastkeys[4] = f
            lastkeys[5] = y
        end

        # Create last constraint
        if isassigned(lastkeys, 1)
            push!(acc2_fuelusebytechnology, @constraint(jumpmodel, sumexps[1] ==
                vusebytechnology[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4],lastkeys[5]]))
        end
    end  # transmissionmodeling

    length(acc2_fuelusebytechnology) > 0 && logmsg("Created constraint Acc2_FuelUseByTechnology.", quiet)
end  # in("vusebytechnology", varstosavearr)
# END: Acc2_FuelUseByTechnology.

# BEGIN: Acc3_AverageAnnualRateOfActivity.
acc3_averageannualrateofactivity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = m, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivity sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, m.val as m, y.val as y, ys.l as l, cast(ys.val as real) as ys
from region r, technology t, mode_of_operation m, year y, YearSplit_def ys
where ys.y = y.val
order by r.val, t.val, m.val, y.val")
    local r = row[:r]
    local t = row[:t]
    local m = row[:m]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || m != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(acc3_averageannualrateofactivity, @constraint(jumpmodel, sumexps[1] ==
            vtotalannualtechnologyactivitybymode[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivity[r,row[:l],t,m,y] * row[:ys])

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = m
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(acc3_averageannualrateofactivity, @constraint(jumpmodel, sumexps[1] ==
        vtotalannualtechnologyactivitybymode[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(acc3_averageannualrateofactivity) > 0 && logmsg("Created constraint Acc3_AverageAnnualRateOfActivity.", quiet)
# END: Acc3_AverageAnnualRateOfActivity.

# BEGIN: Acc4_ModelPeriodCostByRegion.
if in("vmodelperiodcostbyregion", varstosavearr)
    acc4_modelperiodcostbyregion::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for r in sregion
        push!(acc4_modelperiodcostbyregion, @constraint(jumpmodel, sum([vtotaldiscountedcost[r,y] for y in syear]) == vmodelperiodcostbyregion[r]))
    end

    length(acc4_modelperiodcostbyregion) > 0 && logmsg("Created constraint Acc4_ModelPeriodCostByRegion.", quiet)
end
# END: Acc4_ModelPeriodCostByRegion.

# BEGIN: NS1_RateOfStorageCharge.
# vrateofstoragechargenn is in terms of energy output/year (e.g., PJ/yr, depending on CapacityToActivityUnit)
ns1_rateofstoragecharge::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = s, lastkeys[3] = l, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivity sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, l.val as l, y.val as y, tts.m as m, tts.t as t
from region r, storage s, TIMESLICE l, year y, TechnologyToStorage_def tts
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where
tts.r = r.val and tts.s = s.val and tts.val = 1
and ns.r is null
order by r.val, s.val, l.val, y.val")
    local r = row[:r]
    local s = row[:s]
    local l = row[:l]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || s != lastkeys[2] || l != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(ns1_rateofstoragecharge, @constraint(jumpmodel, sumexps[1] ==
            vrateofstoragechargenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivity[r,l,row[:t],row[:m],y])

    lastkeys[1] = r
    lastkeys[2] = s
    lastkeys[3] = l
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(ns1_rateofstoragecharge, @constraint(jumpmodel, sumexps[1] ==
        vrateofstoragechargenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(ns1_rateofstoragecharge) > 0 && logmsg("Created constraint NS1_RateOfStorageCharge.", quiet)
# END: NS1_RateOfStorageCharge.

# BEGIN: NS1Tr_RateOfStorageCharge.
# vrateofstoragechargenodal is in terms of energy output/year (e.g., PJ/yr, depending on CapacityToActivityUnit)
if transmissionmodeling
    ns1tr_rateofstoragecharge::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = s, lastkeys[3] = l, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivitynodal sum

    for row in SQLite.DBInterface.execute(db, "select ns.n as n, ns.s as s, l.val as l, ns.y as y, tts.m as m, tts.t as t
        from nodalstorage ns, TIMESLICE l, TechnologyToStorage_def tts,
    	NodalDistributionTechnologyCapacity_def ntc, TransmissionModelingEnabled tme,
    	(select r, t, f, m, y from OutputActivityRatio_def
        where val <> 0
        union
        select r, t, f, m, y from InputActivityRatio_def
        where val <> 0) ar
    where
    tts.r = ns.r and tts.s = ns.s and tts.val = 1
    and ntc.n = ns.n and ntc.t = tts.t and ntc.y = ns.y and ntc.val > 0
    and tme.r = ns.r and tme.f = ar.f and tme.y = ns.y
    and ar.r = ns.r and ar.t = tts.t and ar.m = tts.m and ar.y = ns.y
    order by ns.n, ns.s, l.val, ns.y")
        local n = row[:n]
        local s = row[:s]
        local l = row[:l]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || s != lastkeys[2] || l != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(ns1tr_rateofstoragecharge, @constraint(jumpmodel, sumexps[1] ==
                vrateofstoragechargenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofactivitynodal[n,l,row[:t],row[:m],y])

        lastkeys[1] = n
        lastkeys[2] = s
        lastkeys[3] = l
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(ns1tr_rateofstoragecharge, @constraint(jumpmodel, sumexps[1] ==
            vrateofstoragechargenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end

    length(ns1tr_rateofstoragecharge) > 0 && logmsg("Created constraint NS1Tr_RateOfStorageCharge.", quiet)
end
# END: NS1Tr_RateOfStorageCharge.

# BEGIN: NS2_RateOfStorageDischarge.
# vrateofstoragedischargenn is in terms of energy output/year (e.g., PJ/yr, depending on CapacityToActivityUnit)
ns2_rateofstoragedischarge::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = s, lastkeys[3] = l, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivity sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, l.val as l, y.val as y, tfs.m as m, tfs.t as t
from region r, storage s, TIMESLICE l, year y, TechnologyFromStorage_def tfs
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where
tfs.r = r.val and tfs.s = s.val and tfs.val = 1
and ns.r is null
order by r.val, s.val, l.val, y.val")
    local r = row[:r]
    local s = row[:s]
    local l = row[:l]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || s != lastkeys[2] || l != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(ns2_rateofstoragedischarge, @constraint(jumpmodel, sumexps[1] ==
            vrateofstoragedischargenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofactivity[r,l,row[:t],row[:m],y])

    lastkeys[1] = r
    lastkeys[2] = s
    lastkeys[3] = l
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(ns2_rateofstoragedischarge, @constraint(jumpmodel, sumexps[1] ==
        vrateofstoragedischargenn[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(ns2_rateofstoragedischarge) > 0 && logmsg("Created constraint NS2_RateOfStorageDischarge.", quiet)
# END: NS2_RateOfStorageDischarge.

# BEGIN: NS2Tr_RateOfStorageDischarge.
# vrateofstoragedischargenodal is in terms of energy output/year (e.g., PJ/yr, depending on CapacityToActivityUnit)
if transmissionmodeling
    ns2tr_rateofstoragedischarge::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = s, lastkeys[3] = l, lastkeys[4] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofactivitynodal sum

    for row in SQLite.DBInterface.execute(db, "select ns.n as n, ns.s as s, l.val as l, ns.y as y, tfs.m as m, tfs.t as t
        from nodalstorage ns, TIMESLICE l, TechnologyFromStorage_def tfs,
    	NodalDistributionTechnologyCapacity_def ntc, TransmissionModelingEnabled tme,
    	(select r, t, f, m, y from OutputActivityRatio_def
        where val <> 0
        union
        select r, t, f, m, y from InputActivityRatio_def
        where val <> 0) ar
    where
    tfs.r = ns.r and tfs.s = ns.s and tfs.val = 1
    and ntc.n = ns.n and ntc.t = tfs.t and ntc.y = ns.y and ntc.val > 0
    and tme.r = ns.r and tme.f = ar.f and tme.y = ns.y
    and ar.r = ns.r and ar.t = tfs.t and ar.m = tfs.m and ar.y = ns.y
    order by ns.n, ns.s, l.val, ns.y")
        local n = row[:n]
        local s = row[:s]
        local l = row[:l]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || s != lastkeys[2] || l != lastkeys[3] || y != lastkeys[4])
            # Create constraint
            push!(ns2tr_rateofstoragedischarge, @constraint(jumpmodel, sumexps[1] ==
                vrateofstoragedischargenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateofactivitynodal[n,l,row[:t],row[:m],y])

        lastkeys[1] = n
        lastkeys[2] = s
        lastkeys[3] = l
        lastkeys[4] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(ns2tr_rateofstoragedischarge, @constraint(jumpmodel, sumexps[1] ==
            vrateofstoragedischargenodal[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
    end

    length(ns2tr_rateofstoragedischarge) > 0 && logmsg("Created constraint NS2Tr_RateOfStorageDischarge.", quiet)
end
# END: NS2Tr_RateOfStorageDischarge.

# BEGIN: NS3_StorageLevelTsGroup1Start, NS4_StorageLevelTsGroup2Start, NS5_StorageLevelTimesliceEnd.
# Note that vstorageleveltsendnn represents storage level (in energy terms) at end of first hour in time slice
ns3_storageleveltsgroup1start::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns4_storageleveltsgroup2start::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns5_storageleveltimesliceend::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, ltg.l as l, y.val as y, ltg.lorder as lo,
    ltg.tg2 as tg2, tg2.[order] as tg2o, ltg.tg1 as tg1, tg1.[order] as tg1o, cast(se.sls as real) as sls,
    cast(msc.val as real) as msc, cast(rsc.delta as real) as rsc_delta
from REGION r, STORAGE s, YEAR y, LTsGroup ltg, TSGROUP2 tg2, TSGROUP1 tg1
left join (select sls.r as r, sls.s as s, sls.val * rsc.val as sls
from StorageLevelStart_def sls, ResidualStorageCapacity_def rsc
where sls.r = rsc.r and sls.s = rsc.s and rsc.y = " * first(syear) * ") se on se.r = r.val and se.s = s.val
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
left join MinStorageCharge_def msc on msc.r = r.val and msc.s = s.val and msc.y = y.val
left join (select r, s, y, val - lag(val) over (partition by r, s order by y) as delta
    from ResidualStorageCapacity) rsc on rsc.r = r.val and rsc.s = s.val and rsc.y = y.val
where
ltg.tg2 = tg2.name
and ltg.tg1 = tg1.name
and ns.r is null")
    local r = row[:r]
    local s = row[:s]
    local l = row[:l]
    local y = row[:y]
    local tg1 = row[:tg1]
    local tg2 = row[:tg2]
    local lo = row[:lo]
    local tg2o = row[:tg2o]
    local tg1o = row[:tg1o]
    local startlevel  # Storage level at beginning of first hour in time slice
    local addns3::Bool = false  # Indicates whether to add to constraint ns3
    local addns4::Bool = false  #  Indicates whether to add to constraint ns4

    if y == first(syear) && tg1o == 1 && tg2o == 1 && lo == 1
        # New endogenous storage capacity is assumed to be delivered with minimum charge
        startlevel = (ismissing(row[:sls]) ? 0 : row[:sls]) + (ismissing(row[:msc]) ? 0 : row[:msc] * vnewstoragecapacity[r,s,y])
        addns3 = true
        addns4 = true
    elseif tg1o == 1 && tg2o == 1 && lo == 1
        startlevel = vstoragelevelyearendnn[r, s, string(Meta.parse(y)-1)]

        # New endogenous and exogenous storage capacity is assumed to be delivered with minimum charge
        # If exogenous capacity is retired, any charge is assumed to be transferred to other capacity existing at start of year; or lost if no capacity exists
        if !ismissing(row[:msc])
            startlevel += row[:msc] * vnewstoragecapacity[r,s,y]

            if !ismissing(row[:rsc_delta]) && row[:rsc_delta] > 0
                startlevel += row[:msc] * row[:rsc_delta]
            end
        end

        addns3 = true
        addns4 = true
    elseif tg2o == 1 && lo == 1
        startlevel = vstorageleveltsgroup1endnn[r, s, tsgroup1dict[tg1o-1][1], y]
        addns3 = true
        addns4 = true
    elseif lo == 1
        startlevel = vstorageleveltsgroup2endnn[r, s, tg1, tsgroup2dict[tg2o-1][1], y]
        addns4 = true
    else
        startlevel = vstorageleveltsendnn[r, s, ltsgroupdict[(tg1o, tg2o, lo-1)], y]
    end

    if addns3
        push!(ns3_storageleveltsgroup1start, @constraint(jumpmodel, startlevel == vstorageleveltsgroup1startnn[r, s, tg1, y]))
    end

    if addns4
        push!(ns4_storageleveltsgroup2start, @constraint(jumpmodel, startlevel == vstorageleveltsgroup2startnn[r, s, tg1, tg2, y]))
    end

    push!(ns5_storageleveltimesliceend, @constraint(jumpmodel,
        startlevel + (vrateofstoragechargenn[r, s, l, y] - vrateofstoragedischargenn[r, s, l, y]) / 8760 == vstorageleveltsendnn[r, s, l, y]))
end

length(ns3_storageleveltsgroup1start) > 0 && logmsg("Created constraint NS3_StorageLevelTsGroup1Start.", quiet)
length(ns4_storageleveltsgroup2start) > 0 && logmsg("Created constraint NS4_StorageLevelTsGroup2Start.", quiet)
length(ns5_storageleveltimesliceend) > 0 && logmsg("Created constraint NS5_StorageLevelTimesliceEnd.", quiet)
# END: NS3_StorageLevelTsGroup1Start, NS4_StorageLevelTsGroup2Start, NS5_StorageLevelTimesliceEnd.

# BEGIN: NS3Tr_StorageLevelTsGroup1Start, NS4Tr_StorageLevelTsGroup2Start, NS5Tr_StorageLevelTimesliceEnd.
# Note that vstorageleveltsendnodal represents storage level (in energy terms) at end of first hour in time slice
if transmissionmodeling
    ns3tr_storageleveltsgroup1start::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns4tr_storageleveltsgroup2start::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns5tr_storageleveltimesliceend::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    # Note that this query distributes StorageLevelStart, MinStorageCharge, and ResidualStorageCapacity according to NodalDistributionStorageCapacity
    for row in SQLite.DBInterface.execute(db, "select ns.r as r, ns.n as n, ns.s as s, ltg.l as l, ns.y as y, ltg.lorder as lo,
        ltg.tg2 as tg2, tg2.[order] as tg2o, ltg.tg1 as tg1, tg1.[order] as tg1o,
    	cast(se.sls * ns.val as real) as sls, cast(msc.val * ns.val as real) as msc, cast(rsc.delta * ns.val as real) as rsc_delta
    from nodalstorage ns, LTsGroup ltg, TSGROUP2 tg2, TSGROUP1 tg1
	left join (select sls.r as r, sls.s as s, sls.val * rsc.val as sls
		from StorageLevelStart_def sls, ResidualStorageCapacity_def rsc
		where sls.r = rsc.r and sls.s = rsc.s and rsc.y = " * first(syear) * ") se on se.r = ns.r and se.s = ns.s
    left join MinStorageCharge_def msc on msc.r = ns.r and msc.s = ns.s and msc.y = ns.y
    left join (select r, s, y, val - lag(val) over (partition by r, s order by y) as delta
        from ResidualStorageCapacity) rsc on rsc.r = ns.r and rsc.s = ns.s and rsc.y = ns.y
    where
    ltg.tg2 = tg2.name
    and ltg.tg1 = tg1.name")
        local r = row[:r]
        local n = row[:n]
        local s = row[:s]
        local l = row[:l]
        local y = row[:y]
        local tg1 = row[:tg1]
        local tg2 = row[:tg2]
        local lo = row[:lo]
        local tg2o = row[:tg2o]
        local tg1o = row[:tg1o]
        local startlevel  # Storage level at beginning of first hour in time slice
        local addns3::Bool = false  # Indicates whether to add to constraint ns3tr
        local addns4::Bool = false  #  Indicates whether to add to constraint ns4tr

        if y == first(syear) && tg1o == 1 && tg2o == 1 && lo == 1
            # New endogenous storage capacity is assumed to be delivered with minimum charge
            startlevel = (ismissing(row[:sls]) ? 0 : row[:sls]) + (ismissing(row[:msc]) ? 0 : row[:msc] * vnewstoragecapacity[r,s,y])
            addns3 = true
            addns4 = true
        elseif tg1o == 1 && tg2o == 1 && lo == 1
            startlevel = vstoragelevelyearendnodal[n, s, string(Meta.parse(y)-1)]

            # New endogenous and exogenous storage capacity is assumed to be delivered with minimum charge
            # If exogenous capacity is retired, any charge is assumed to be transferred to other capacity existing at start of year; or lost if no capacity exists
            if !ismissing(row[:msc])
                startlevel += row[:msc] * vnewstoragecapacity[r,s,y]

                if !ismissing(row[:rsc_delta]) && row[:rsc_delta] > 0
                    startlevel += row[:msc] * row[:rsc_delta]
                end
            end

            addns3 = true
            addns4 = true
        elseif tg2o == 1 && lo == 1
            startlevel = vstorageleveltsgroup1endnodal[n, s, tsgroup1dict[tg1o-1][1], y]
            addns3 = true
            addns4 = true
        elseif lo == 1
            startlevel = vstorageleveltsgroup2endnodal[n, s, tg1, tsgroup2dict[tg2o-1][1], y]
            addns4 = true
        else
            startlevel = vstorageleveltsendnodal[n, s, ltsgroupdict[(tg1o, tg2o, lo-1)], y]
        end

        if addns3
            push!(ns3tr_storageleveltsgroup1start, @constraint(jumpmodel, startlevel == vstorageleveltsgroup1startnodal[n, s, tg1, y]))
        end

        if addns4
            push!(ns4tr_storageleveltsgroup2start, @constraint(jumpmodel, startlevel == vstorageleveltsgroup2startnodal[n, s, tg1, tg2, y]))
        end

        push!(ns5tr_storageleveltimesliceend, @constraint(jumpmodel,
            startlevel + (vrateofstoragechargenodal[n, s, l, y] - vrateofstoragedischargenodal[n, s, l, y]) / 8760 == vstorageleveltsendnodal[n, s, l, y]))
    end

    length(ns3tr_storageleveltsgroup1start) > 0 && logmsg("Created constraint NS3Tr_StorageLevelTsGroup1Start.", quiet)
    length(ns4tr_storageleveltsgroup2start) > 0 && logmsg("Created constraint NS4Tr_StorageLevelTsGroup2Start.", quiet)
    length(ns5tr_storageleveltimesliceend) > 0 && logmsg("Created constraint NS5Tr_StorageLevelTimesliceEnd.", quiet)
end
# END: NS3Tr_StorageLevelTsGroup1Start, NS4Tr_StorageLevelTsGroup2Start, NS5Tr_StorageLevelTimesliceEnd.

# BEGIN: NS6_StorageLevelTsGroup2End and NS6a_StorageLevelTsGroup2NetZero.
ns6_storageleveltsgroup2end::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns6a_storageleveltsgroup2netzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select main.r, main.s, main.tg2nz, main.tg1, main.tg1o, main.tg2, main.tg2o, cast(main.tg2m as real) as tg2m,
    main.y, ltg2.l as maxl, main.maxlo
from
(select r.val as r, s.val as s, s.netzerotg2 as tg2nz, tg1.name as tg1, tg1.[order] as tg1o, tg2.name as tg2, tg2.[order] as tg2o, tg2.multiplier as tg2m,
y.val as y, max(ltg.lorder) as maxlo
from REGION r, STORAGE s, TSGROUP1 tg1, TSGROUP2 tg2, YEAR as y, LTsGroup ltg
where
tg1.name = ltg.tg1
and tg2.name = ltg.tg2
group by r.val, s.val, s.netzerotg2, tg1.name, tg1.[order], tg2.name, tg2.[order], tg2.multiplier, y.val) main, LTsGroup ltg2
left join nodalstorage ns on ns.r = main.r and ns.s = main.s and ns.y = main.y
where
ltg2.tg1 = main.tg1
and ltg2.tg2 = main.tg2
and ltg2.lorder = main.maxlo
and ns.r is null")
    local r = row[:r]
    local s = row[:s]
    local tg2nz = row[:tg2nz]  # 1 = tg2 end level must = tg2 start level
    local tg1 = row[:tg1]
    local tg2 = row[:tg2]
    local y = row[:y]

    push!(ns6_storageleveltsgroup2end, @constraint(jumpmodel, vstorageleveltsgroup2startnn[r, s, tg1, tg2, y] +
        (vstorageleveltsendnn[r, s, row[:maxl], y] - vstorageleveltsgroup2startnn[r, s, tg1, tg2, y]) * row[:tg2m]
        == vstorageleveltsgroup2endnn[r, s, tg1, tg2, y]))

    if tg2nz == 1
        push!(ns6a_storageleveltsgroup2netzero, @constraint(jumpmodel, vstorageleveltsgroup2startnn[r, s, tg1, tg2, y]
            == vstorageleveltsgroup2endnn[r, s, tg1, tg2, y]))
    end
end

length(ns6_storageleveltsgroup2end) > 0 && logmsg("Created constraint NS6_StorageLevelTsGroup2End.", quiet)
length(ns6a_storageleveltsgroup2netzero) > 0 && logmsg("Created constraint NS6a_StorageLevelTsGroup2NetZero.", quiet)
# END: NS6_StorageLevelTsGroup2End and NS6a_StorageLevelTsGroup2NetZero.

# BEGIN: NS6Tr_StorageLevelTsGroup2End and NS6aTr_StorageLevelTsGroup2NetZero.
if transmissionmodeling
    ns6tr_storageleveltsgroup2end::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns6atr_storageleveltsgroup2netzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select main.n, main.s, main.tg2nz, main.tg1, main.tg1o, main.tg2, main.tg2o, cast(main.tg2m as real) as tg2m,
        main.y, ltg2.l as maxl, main.maxlo
    from
    (select ns.n as n, ns.s as s, s.netzerotg2 as tg2nz, tg1.name as tg1, tg1.[order] as tg1o, tg2.name as tg2, tg2.[order] as tg2o,
    tg2.multiplier as tg2m, ns.y as y, max(ltg.lorder) as maxlo
    from nodalstorage ns, STORAGE s, TSGROUP1 tg1, TSGROUP2 tg2, LTsGroup ltg
    where
    ns.s = s.val
    and tg1.name = ltg.tg1
    and tg2.name = ltg.tg2
    group by ns.n, ns.s, s.netzerotg2, tg1.name, tg1.[order], tg2.name, tg2.[order], tg2.multiplier, ns.y) main, LTsGroup ltg2
    where
    ltg2.tg1 = main.tg1
    and ltg2.tg2 = main.tg2
    and ltg2.lorder = main.maxlo")
        local n = row[:n]
        local s = row[:s]
        local tg2nz = row[:tg2nz]  # 1 = tg2 end level must = tg2 start level
        local tg1 = row[:tg1]
        local tg2 = row[:tg2]
        local y = row[:y]

        push!(ns6tr_storageleveltsgroup2end, @constraint(jumpmodel, vstorageleveltsgroup2startnodal[n, s, tg1, tg2, y] +
            (vstorageleveltsendnodal[n, s, row[:maxl], y] - vstorageleveltsgroup2startnodal[n, s, tg1, tg2, y]) * row[:tg2m]
            == vstorageleveltsgroup2endnodal[n, s, tg1, tg2, y]))

        if tg2nz == 1
            push!(ns6atr_storageleveltsgroup2netzero, @constraint(jumpmodel, vstorageleveltsgroup2startnodal[n, s, tg1, tg2, y]
                == vstorageleveltsgroup2endnodal[n, s, tg1, tg2, y]))
        end
    end

    length(ns6tr_storageleveltsgroup2end) > 0 && logmsg("Created constraint NS6Tr_StorageLevelTsGroup2End.", quiet)
    length(ns6atr_storageleveltsgroup2netzero) > 0 && logmsg("Created constraint NS6aTr_StorageLevelTsGroup2NetZero.", quiet)
end
# END: NS6Tr_StorageLevelTsGroup2End and NS6aTr_StorageLevelTsGroup2NetZero.

# BEGIN: NS7_StorageLevelTsGroup1End and NS7a_StorageLevelTsGroup1NetZero.
ns7_storageleveltsgroup1end::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns7a_storageleveltsgroup1netzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s,
	case s.netzerotg2 when 1 then 0 else s.netzerotg1 end as tg1nz,
	tg1.name as tg1, tg1.[order] as tg1o, cast(tg1.multiplier as real) as tg1m,
    y.val as y, max(tg2.[order]) as maxtg2o
from REGION r, STORAGE s, TSGROUP1 tg1, YEAR as y, LTsGroup ltg, TSGROUP2 tg2
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where
tg1.name = ltg.tg1
and ltg.tg2 = tg2.name
and ns.r is null
group by r.val, s.val, tg1.name, tg1.[order], tg1.multiplier, y.val")
    local r = row[:r]
    local s = row[:s]
    local tg1nz = row[:tg1nz]  # 1 = tg1 end level must = tg1 start level (zeroed out when tg2 net zero is activated as tg1 check isn't necessary)
    local tg1 = row[:tg1]
    local y = row[:y]

    push!(ns7_storageleveltsgroup1end, @constraint(jumpmodel, vstorageleveltsgroup1startnn[r, s, tg1, y] +
        (vstorageleveltsgroup2endnn[r, s, tg1, tsgroup2dict[row[:maxtg2o]][1], y] - vstorageleveltsgroup1startnn[r, s, tg1, y]) * row[:tg1m]
        == vstorageleveltsgroup1endnn[r, s, tg1, y]))

    if tg1nz == 1
        push!(ns7a_storageleveltsgroup1netzero, @constraint(jumpmodel, vstorageleveltsgroup1startnn[r, s, tg1, y]
            == vstorageleveltsgroup1endnn[r, s, tg1, y]))
    end
end

length(ns7_storageleveltsgroup1end) > 0 && logmsg("Created constraint NS7_StorageLevelTsGroup1End.", quiet)
length(ns7a_storageleveltsgroup1netzero) > 0 && logmsg("Created constraint NS7a_StorageLevelTsGroup1NetZero.", quiet)
# END: NS7_StorageLevelTsGroup1End and NS7a_StorageLevelTsGroup1NetZero.

# BEGIN: NS7Tr_StorageLevelTsGroup1End and NS7aTr_StorageLevelTsGroup1NetZero.
if transmissionmodeling
    ns7tr_storageleveltsgroup1end::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns7atr_storageleveltsgroup1netzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.n as n, ns.s as s,
        	case s.netzerotg2 when 1 then 0 else s.netzerotg1 end as tg1nz,
        	tg1.name as tg1, tg1.[order] as tg1o, cast(tg1.multiplier as real) as tg1m,
            ns.y as y, max(tg2.[order]) as maxtg2o
        from nodalstorage ns, STORAGE s, TSGROUP1 tg1, LTsGroup ltg, TSGROUP2 tg2
    where
    ns.s = s.val
    and tg1.name = ltg.tg1
    and ltg.tg2 = tg2.name
    group by ns.n, ns.s, tg1.name, tg1.[order], tg1.multiplier, ns.y")
        local n = row[:n]
        local s = row[:s]
        local tg1nz = row[:tg1nz]  # 1 = tg1 end level must = tg1 start level (zeroed out when tg2 net zero is activated as tg1 check isn't necessary)
        local tg1 = row[:tg1]
        local y = row[:y]

        push!(ns7tr_storageleveltsgroup1end, @constraint(jumpmodel, vstorageleveltsgroup1startnodal[n, s, tg1, y] +
            (vstorageleveltsgroup2endnodal[n, s, tg1, tsgroup2dict[row[:maxtg2o]][1], y] - vstorageleveltsgroup1startnodal[n, s, tg1, y]) * row[:tg1m]
            == vstorageleveltsgroup1endnodal[n, s, tg1, y]))

        if tg1nz == 1
            push!(ns7atr_storageleveltsgroup1netzero, @constraint(jumpmodel, vstorageleveltsgroup1startnodal[n, s, tg1, y]
                == vstorageleveltsgroup1endnodal[n, s, tg1, y]))
        end
    end

    length(ns7tr_storageleveltsgroup1end) > 0 && logmsg("Created constraint NS7Tr_StorageLevelTsGroup1End.", quiet)
    length(ns7atr_storageleveltsgroup1netzero) > 0 && logmsg("Created constraint NS7aTr_StorageLevelTsGroup1NetZero.", quiet)
end
# END: NS7Tr_StorageLevelTsGroup1End and NS7aTr_StorageLevelTsGroup1NetZero.

# BEGIN: NS8_StorageLevelYearEnd and NS8a_StorageLevelYearEndNetZero.
ns8_storagelevelyearend::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns8a_storagelevelyearendnetzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = s, lastkeys[3] = y
lastvals = Array{Float64, 1}([0.0, 0.0, 0.0])  # lastvals[1] = sls, lastvals[2] = msc, lastvals[3] = rsc_delta
lastvalsint = Array{Int64, 1}(undef,1)  # lastvalsint[1] = ynz
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofstoragechargenn and vrateofstoragedischargenn sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s,
case s.netzerotg2 when 1 then 0 else case s.netzerotg1 when 1 then 0 else s.netzeroyear end end as ynz,
y.val as y, ys.l as l, cast(ys.val as real) as ys,
cast(se.sls as real) as sls, cast(msc.val as real) as msc, cast(rsc.delta as real) as rsc_delta
from REGION r, STORAGE s, YEAR as y, YearSplit_def ys
left join (select sls.r as r, sls.s as s, sls.val * rsc.val as sls
from StorageLevelStart_def sls, ResidualStorageCapacity_def rsc
where sls.r = rsc.r and sls.s = rsc.s and rsc.y = " * first(syear) * ") se on se.r = r.val and se.s = s.val
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
left join MinStorageCharge_def msc on msc.r = r.val and msc.s = s.val and msc.y = y.val
left join (select r, s, y, val - lag(val) over (partition by r, s order by y) as delta
    from ResidualStorageCapacity) rsc on rsc.r = r.val and rsc.s = s.val and rsc.y = y.val
where y.val = ys.y
and ns.r is null
order by r.val, s.val, y.val")
    local r = row[:r]
    local s = row[:s]
    local ynz = row[:ynz]  # 1 = year end level must = year start level (zeroed out when tg2 net zero or tg1 net zero is activated as year check isn't necessary)
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || s != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        # New endogenous and exogenous storage capacity is assumed to be delivered with minimum charge
        # If exogenous capacity is retired, any charge is assumed to be transferred to other capacity existing at start of year; or lost if no capacity exists
        push!(ns8_storagelevelyearend, @constraint(jumpmodel,
            (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnn[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
            + lastvals[2] * vnewstoragecapacity[lastkeys[1], lastkeys[2], lastkeys[3]]
            + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0) + sumexps[1]
            == vstoragelevelyearendnn[lastkeys[1], lastkeys[2], lastkeys[3]]))

        if lastvalsint[1] == 1
            push!(ns8a_storagelevelyearendnetzero, @constraint(jumpmodel,
                (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnn[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
                + lastvals[2] * vnewstoragecapacity[lastkeys[1], lastkeys[2], lastkeys[3]]
                + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0)
                == vstoragelevelyearendnn[lastkeys[1], lastkeys[2], lastkeys[3]]))
        end

        sumexps[1] = AffExpr()
        lastvals = [0.0, 0.0, 0.0]
        lastvalsint[1] = 0
    end

    append!(sumexps[1], (vrateofstoragechargenn[r,s,row[:l],y] - vrateofstoragedischargenn[r,s,row[:l],y]) * row[:ys])

    if !ismissing(row[:sls])
        lastvals[1] = row[:sls]
    end

    if !ismissing(row[:msc])
        lastvals[2] = row[:msc]
    end

    if !ismissing(row[:rsc_delta])
        lastvals[3] = row[:rsc_delta]
    end

    lastvalsint[1] = ynz
    lastkeys[1] = r
    lastkeys[2] = s
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(ns8_storagelevelyearend, @constraint(jumpmodel,
        (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnn[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
        + lastvals[2] * vnewstoragecapacity[lastkeys[1], lastkeys[2], lastkeys[3]]
        + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0) + sumexps[1]
        == vstoragelevelyearendnn[lastkeys[1], lastkeys[2], lastkeys[3]]))

    if lastvalsint[1] == 1
        push!(ns8a_storagelevelyearendnetzero, @constraint(jumpmodel,
            (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnn[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
            + lastvals[2] * vnewstoragecapacity[lastkeys[1], lastkeys[2], lastkeys[3]]
            + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0)
            == vstoragelevelyearendnn[lastkeys[1], lastkeys[2], lastkeys[3]]))
    end
end

length(ns8_storagelevelyearend) > 0 && logmsg("Created constraint NS8_StorageLevelYearEnd.", quiet)
length(ns8a_storagelevelyearendnetzero) > 0 && logmsg("Created constraint NS8a_StorageLevelYearEndNetZero.", quiet)
# END: NS8_StorageLevelYearEnd and NS8a_StorageLevelYearEndNetZero.

# BEGIN: NS8Tr_StorageLevelYearEnd and NS8aTr_StorageLevelYearEndNetZero.
if transmissionmodeling
    ns8tr_storagelevelyearend::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns8atr_storagelevelyearendnetzero::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = n, lastkeys[2] = s, lastkeys[3] = y, lastkeys[4] = r
    lastvals = Array{Float64, 1}([0.0, 0.0, 0.0])  # lastvals[1] = sls, lastvals[2] = msc, lastvals[3] = rsc_delta
    lastvalsint = Array{Int64, 1}(undef,1)  # lastvalsint[1] = ynz
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofstoragechargenodal and vrateofstoragedischargenodal sum

    # Note that this query distributes StorageLevelStart, MinStorageCharge, and ResidualStorageCapacity according to NodalDistributionStorageCapacity
    for row in SQLite.DBInterface.execute(db, "select ns.r as r, ns.n as n, s.val as s,
    case s.netzerotg2 when 1 then 0 else case s.netzerotg1 when 1 then 0 else s.netzeroyear end end as ynz,
    ns.y as y, ys.l as l, cast(ys.val as real) as ys,
    cast(se.sls * ns.val as real) as sls, cast(msc.val * ns.val as real) as msc,
    cast(rsc.delta * ns.val as real) as rsc_delta
    from nodalstorage ns, STORAGE s, YearSplit_def ys
    left join (select sls.r as r, sls.s as s, sls.val * rsc.val as sls
		from StorageLevelStart_def sls, ResidualStorageCapacity_def rsc
		where sls.r = rsc.r and sls.s = rsc.s and rsc.y = " * first(syear) * ") se on se.r = ns.r and se.s = ns.s
    left join MinStorageCharge_def msc on msc.r = ns.r and msc.s = s.val and msc.y = ns.y
    left join (select r, s, y, val - lag(val) over (partition by r, s order by y) as delta
		from ResidualStorageCapacity) rsc on rsc.r = ns.r and rsc.s = s.val and rsc.y = ns.y
    where ns.s = s.val
	and ns.y = ys.y
    order by ns.n, ns.s, ns.y")
        local n = row[:n]
        local s = row[:s]
        local ynz = row[:ynz]  # 1 = year end level must = year start level (zeroed out when tg2 net zero or tg1 net zero is activated as year check isn't necessary)
        local y = row[:y]

        if isassigned(lastkeys, 1) && (n != lastkeys[1] || s != lastkeys[2] || y != lastkeys[3])
            # Create constraint
            # New endogenous and exogenous storage capacity is assumed to be delivered with minimum charge
            # If exogenous capacity is retired, any charge is assumed to be transferred to other capacity existing at start of year; or lost if no capacity exists
            push!(ns8tr_storagelevelyearend, @constraint(jumpmodel,
                (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
                + lastvals[2] * vnewstoragecapacity[lastkeys[4], lastkeys[2], lastkeys[3]]
                + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0) + sumexps[1]
                == vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], lastkeys[3]]))

            if lastvalsint[1] == 1
                push!(ns8atr_storagelevelyearendnetzero, @constraint(jumpmodel,
                    (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
                    + lastvals[2] * vnewstoragecapacity[lastkeys[4], lastkeys[2], lastkeys[3]]
                    + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0)
                    == vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], lastkeys[3]]))
            end

            sumexps[1] = AffExpr()
            lastvals = [0.0, 0.0, 0.0]
            lastvalsint[1] = 0
        end

        append!(sumexps[1], (vrateofstoragechargenodal[n,s,row[:l],y] - vrateofstoragedischargenodal[n,s,row[:l],y]) * row[:ys])

        if !ismissing(row[:sls])
            lastvals[1] = row[:sls]
        end

        if !ismissing(row[:msc])
            lastvals[2] = row[:msc]
        end

        if !ismissing(row[:rsc_delta])
            lastvals[3] = row[:rsc_delta]
        end

        lastvalsint[1] = ynz
        lastkeys[1] = n
        lastkeys[2] = s
        lastkeys[3] = y
        lastkeys[4] = row[:r]
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(ns8tr_storagelevelyearend, @constraint(jumpmodel,
            (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
            + lastvals[2] * vnewstoragecapacity[lastkeys[4], lastkeys[2], lastkeys[3]]
            + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0) + sumexps[1]
            == vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], lastkeys[3]]))

        if lastvalsint[1] == 1
            push!(ns8atr_storagelevelyearendnetzero, @constraint(jumpmodel,
                (lastkeys[3] == first(syear) ? lastvals[1] : vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], string(Meta.parse(lastkeys[3])-1)])
                + lastvals[2] * vnewstoragecapacity[lastkeys[4], lastkeys[2], lastkeys[3]]
                + lastvals[2] * (lastvals[3] > 0 ? lastvals[3] : 0)
                == vstoragelevelyearendnodal[lastkeys[1], lastkeys[2], lastkeys[3]]))
        end
    end

    length(ns8tr_storagelevelyearend) > 0 && logmsg("Created constraint NS8Tr_StorageLevelYearEnd.", quiet)
    length(ns8atr_storagelevelyearendnetzero) > 0 && logmsg("Created constraint NS8aTr_StorageLevelYearEndNetZero.", quiet)
end
# END: NS8Tr_StorageLevelYearEnd and NS8aTr_StorageLevelYearEndNetZero.

# BEGIN: SI1_StorageUpperLimit.
si1_storageupperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(rsc.val as real) as rsc
from region r, storage s, year y
left join ResidualStorageCapacity_def rsc on rsc.r = r.val and rsc.s = s.val and rsc.y = y.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si1_storageupperlimit, @constraint(jumpmodel, vaccumulatednewstoragecapacity[r,s,y] + (ismissing(row[:rsc]) ? 0 : row[:rsc]) == vstorageupperlimit[r,s,y]))
end

length(si1_storageupperlimit) > 0 && logmsg("Created constraint SI1_StorageUpperLimit.", quiet)
# END: SI1_StorageUpperLimit.

# BEGIN: SI2_StorageLowerLimit.
si2_storagelowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(msc.val as real) as msc
from region r, storage s, year y, MinStorageCharge_def msc
where msc.r = r.val and msc.s = s.val and msc.y = y.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si2_storagelowerlimit, @constraint(jumpmodel, row[:msc] * vstorageupperlimit[r,s,y] == vstoragelowerlimit[r,s,y]))
end

length(si2_storagelowerlimit) > 0 && logmsg("Created constraint SI2_StorageLowerLimit.", quiet)
# END: SI2_StorageLowerLimit.

# BEGIN: SI3_TotalNewStorage.
si3_totalnewstorage::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = s, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vnewstoragecapacity sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(ols.val as real) as ols, yy.val as yy
from region r, storage s, year y, OperationalLifeStorage_def ols, year yy
where ols.r = r.val and ols.s = s.val
and y.val - yy.val < ols.val and y.val - yy.val >= 0
order by r.val, s.val, y.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || s != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(si3_totalnewstorage, @constraint(jumpmodel, sumexps[1] ==
            vaccumulatednewstoragecapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vnewstoragecapacity[r,s,row[:yy]])

    lastkeys[1] = r
    lastkeys[2] = s
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(si3_totalnewstorage, @constraint(jumpmodel, sumexps[1] ==
        vaccumulatednewstoragecapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(si3_totalnewstorage) > 0 && logmsg("Created constraint SI3_TotalNewStorage.", quiet)
# END: SI3_TotalNewStorage.

# BEGIN: NS9a_StorageLevelTsLowerLimit and NS9b_StorageLevelTsUpperLimit.
ns9a_storageleveltslowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns9b_storageleveltsupperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, l.val as l, y.val as y
from REGION r, STORAGE s, TIMESLICE l, YEAR y
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where ns.r is null")
    local r = row[:r]
    local s = row[:s]
    local l = row[:l]
    local y = row[:y]

    push!(ns9a_storageleveltslowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] <= vstorageleveltsendnn[r,s,l,y]))
    push!(ns9b_storageleveltsupperlimit, @constraint(jumpmodel, vstorageleveltsendnn[r,s,l,y] <= vstorageupperlimit[r,s,y]))
end

length(ns9a_storageleveltslowerlimit) > 0 && logmsg("Created constraint NS9a_StorageLevelTsLowerLimit.", quiet)
length(ns9b_storageleveltsupperlimit) > 0 && logmsg("Created constraint NS9b_StorageLevelTsUpperLimit.", quiet)
# END: NS9a_StorageLevelTsLowerLimit and NS9b_StorageLevelTsUpperLimit.

# BEGIN: NS9aTr_StorageLevelTsLowerLimit and NS9bTr_StorageLevelTsUpperLimit.
if transmissionmodeling
    ns9atr_storageleveltslowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns9btr_storageleveltsupperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.r as r, ns.n as n, ns.s as s, l.val as l, ns.y as y, cast(ns.val as real) as nsc
    from nodalstorage ns, TIMESLICE l")
        local r = row[:r]
        local n = row[:n]
        local s = row[:s]
        local l = row[:l]
        local y = row[:y]
        local nsc = row[:nsc]

        push!(ns9atr_storageleveltslowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] * nsc <= vstorageleveltsendnodal[n,s,l,y]))
        push!(ns9btr_storageleveltsupperlimit, @constraint(jumpmodel, vstorageleveltsendnodal[n,s,l,y] <= vstorageupperlimit[r,s,y] * nsc))
    end

    length(ns9atr_storageleveltslowerlimit) > 0 && logmsg("Created constraint NS9aTr_StorageLevelTsLowerLimit.", quiet)
    length(ns9btr_storageleveltsupperlimit) > 0 && logmsg("Created constraint NS9bTr_StorageLevelTsUpperLimit.", quiet)
end
# END: NS9aTr_StorageLevelTsLowerLimit and NS9bTr_StorageLevelTsUpperLimit.

# BEGIN: NS10_StorageChargeLimit.
ns10_storagechargelimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, l.val as l, y.val as y, cast(smc.val as real) as smc
from region r, storage s, TIMESLICE l, year y, StorageMaxChargeRate_def smc
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where
r.val = smc.r
and s.val = smc.s
and ns.r is null")
    push!(ns10_storagechargelimit, @constraint(jumpmodel, vrateofstoragechargenn[row[:r], row[:s], row[:l], row[:y]] <= row[:smc]))
end

length(ns10_storagechargelimit) > 0 && logmsg("Created constraint NS10_StorageChargeLimit.", quiet)
# END: NS10_StorageChargeLimit.

# BEGIN: NS10Tr_StorageChargeLimit.
if transmissionmodeling
    ns10tr_storagechargelimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.n as n, ns.s as s, l.val as l, ns.y as y, cast(smc.val as real) as smc
    from nodalstorage ns, TIMESLICE l, StorageMaxChargeRate_def smc
    where
    ns.r = smc.r and ns.s = smc.s")
        push!(ns10tr_storagechargelimit, @constraint(jumpmodel, vrateofstoragechargenodal[row[:n], row[:s], row[:l], row[:y]] <= row[:smc]))
    end

    length(ns10tr_storagechargelimit) > 0 && logmsg("Created constraint NS10Tr_StorageChargeLimit.", quiet)
end
# END: NS10Tr_StorageChargeLimit.

# BEGIN: NS11_StorageDischargeLimit.
ns11_storagedischargelimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, l.val as l, y.val as y, cast(smd.val as real) as smd
from region r, storage s, TIMESLICE l, year y, StorageMaxDischargeRate_def smd
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where
r.val = smd.r
and s.val = smd.s
and ns.r is null")
    push!(ns11_storagedischargelimit, @constraint(jumpmodel, vrateofstoragedischargenn[row[:r], row[:s], row[:l], row[:y]] <= row[:smd]))
end

length(ns11_storagedischargelimit) > 0 && logmsg("Created constraint NS11_StorageDischargeLimit.", quiet)
# END: NS11_StorageDischargeLimit.

# BEGIN: NS11Tr_StorageDischargeLimit.
if transmissionmodeling
    ns11tr_storagedischargelimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.n as n, ns.s as s, l.val as l, ns.y as y, cast(smd.val as real) as smd
    from nodalstorage ns, TIMESLICE l, StorageMaxDischargeRate_def smd
    where
    ns.r = smd.r and ns.s = smd.s")
        push!(ns11tr_storagedischargelimit, @constraint(jumpmodel, vrateofstoragedischargenodal[row[:n], row[:s], row[:l], row[:y]] <= row[:smd]))
    end

    length(ns11tr_storagedischargelimit) > 0 && logmsg("Created constraint NS11Tr_StorageDischargeLimit.", quiet)
end
# END: NS11Tr_StorageDischargeLimit.

# BEGIN: NS12a_StorageLevelTsGroup2LowerLimit and NS12b_StorageLevelTsGroup2UpperLimit.
ns12a_storageleveltsgroup2lowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns12b_storageleveltsgroup2upperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, tg1.name as tg1, tg2.name as tg2, y.val as y
from REGION r, STORAGE s, TSGROUP1 tg1, TSGROUP2 tg2, YEAR y
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where ns.r is null")
    local r = row[:r]
    local s = row[:s]
    local tg1 = row[:tg1]
    local tg2 = row[:tg2]
    local y = row[:y]

    push!(ns12a_storageleveltsgroup2lowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] <= vstorageleveltsgroup2endnn[r,s,tg1,tg2,y]))
    push!(ns12b_storageleveltsgroup2upperlimit, @constraint(jumpmodel, vstorageleveltsgroup2endnn[r,s,tg1,tg2,y] <= vstorageupperlimit[r,s,y]))
end

length(ns12a_storageleveltsgroup2lowerlimit) > 0 && logmsg("Created constraint NS12a_StorageLevelTsGroup2LowerLimit.", quiet)
length(ns12b_storageleveltsgroup2upperlimit) > 0 && logmsg("Created constraint NS12b_StorageLevelTsGroup2UpperLimit.", quiet)
# END: NS12a_StorageLevelTsGroup2LowerLimit and NS12b_StorageLevelTsGroup2UpperLimit.

# BEGIN: NS12aTr_StorageLevelTsGroup2LowerLimit and NS12bTr_StorageLevelTsGroup2UpperLimit.
if transmissionmodeling
    ns12atr_storageleveltsgroup2lowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns12btr_storageleveltsgroup2upperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.r as r, ns.n as n, ns.s as s, tg1.name as tg1, tg2.name as tg2, ns.y as y, cast(ns.val as real) as nsc
    from nodalstorage ns, TSGROUP1 tg1, TSGROUP2 tg2")
        local r = row[:r]
        local n = row[:n]
        local s = row[:s]
        local tg1 = row[:tg1]
        local tg2 = row[:tg2]
        local y = row[:y]
        local nsc = row[:nsc]

        push!(ns12atr_storageleveltsgroup2lowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] * nsc <= vstorageleveltsgroup2endnodal[n,s,tg1,tg2,y]))
        push!(ns12btr_storageleveltsgroup2upperlimit, @constraint(jumpmodel, vstorageleveltsgroup2endnodal[n,s,tg1,tg2,y] <= vstorageupperlimit[r,s,y] * nsc))
    end

    length(ns12atr_storageleveltsgroup2lowerlimit) > 0 && logmsg("Created constraint NS12aTr_StorageLevelTsGroup2LowerLimit.", quiet)
    length(ns12btr_storageleveltsgroup2upperlimit) > 0 && logmsg("Created constraint NS12bTr_StorageLevelTsGroup2UpperLimit.", quiet)
end
# END: NS12aTr_StorageLevelTsGroup2LowerLimit and NS12bTr_StorageLevelTsGroup2UpperLimit.

# BEGIN: NS13a_StorageLevelTsGroup1LowerLimit and NS13b_StorageLevelTsGroup1UpperLimit.
ns13a_storageleveltsgroup1lowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
ns13b_storageleveltsgroup1upperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, tg1.name as tg1, y.val as y
from REGION r, STORAGE s, TSGROUP1 tg1, YEAR y
left join nodalstorage ns on ns.r = r.val and ns.s = s.val and ns.y = y.val
where ns.r is null")
    local r = row[:r]
    local s = row[:s]
    local tg1 = row[:tg1]
    local y = row[:y]

    push!(ns13a_storageleveltsgroup1lowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] <= vstorageleveltsgroup1endnn[r,s,tg1,y]))
    push!(ns13b_storageleveltsgroup1upperlimit, @constraint(jumpmodel, vstorageleveltsgroup1endnn[r,s,tg1,y] <= vstorageupperlimit[r,s,y]))
end

length(ns13a_storageleveltsgroup1lowerlimit) > 0 && logmsg("Created constraint NS13a_StorageLevelTsGroup1LowerLimit.", quiet)
length(ns13b_storageleveltsgroup1upperlimit) > 0 && logmsg("Created constraint NS13b_StorageLevelTsGroup1UpperLimit.", quiet)
# END: NS13a_StorageLevelTsGroup2LowerLimit and NS13b_StorageLevelTsGroup2UpperLimit.

# BEGIN: NS13aTr_StorageLevelTsGroup1LowerLimit and NS13bTr_StorageLevelTsGroup1UpperLimit.
if transmissionmodeling
    ns13atr_storageleveltsgroup1lowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    ns13btr_storageleveltsgroup1upperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select ns.r as r, ns.n as n, ns.s as s, tg1.name as tg1, ns.y as y, cast(ns.val as real) as nsc
    from nodalstorage ns, TSGROUP1 tg1")
        local r = row[:r]
        local n = row[:n]
        local s = row[:s]
        local tg1 = row[:tg1]
        local y = row[:y]
        local nsc = row[:nsc]

        push!(ns13atr_storageleveltsgroup1lowerlimit, @constraint(jumpmodel, vstoragelowerlimit[r,s,y] * nsc <= vstorageleveltsgroup1endnodal[n,s,tg1,y]))
        push!(ns13btr_storageleveltsgroup1upperlimit, @constraint(jumpmodel, vstorageleveltsgroup1endnodal[n,s,tg1,y] <= vstorageupperlimit[r,s,y] * nsc))
    end

    length(ns13atr_storageleveltsgroup1lowerlimit) > 0 && logmsg("Created constraint NS13aTr_StorageLevelTsGroup2LowerLimit.", quiet)
    length(ns13btr_storageleveltsgroup1upperlimit) > 0 && logmsg("Created constraint NS13bTr_StorageLevelTsGroup2UpperLimit.", quiet)
end
# END: NS13aTr_StorageLevelTsGroup2LowerLimit and NS13bTr_StorageLevelTsGroup2UpperLimit.

# BEGIN: NS14_MaxStorageCapacity.
ns14_maxstoragecapacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select smc.r, smc.s, smc.y, cast(smc.val as real) as smc
from TotalAnnualMaxCapacityStorage_def smc")
    push!(ns14_maxstoragecapacity, @constraint(jumpmodel, vstorageupperlimit[row[:r],row[:s],row[:y]] <= row[:smc]))
end

length(ns14_maxstoragecapacity) > 0 && logmsg("Created constraint NS14_MaxStorageCapacity.", quiet)
# END: NS14_MaxStorageCapacity.

# BEGIN: NS15_MinStorageCapacity.
ns15_minstoragecapacity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select smc.r, smc.s, smc.y, cast(smc.val as real) as smc
from TotalAnnualMinCapacityStorage_def smc")
    push!(ns15_minstoragecapacity, @constraint(jumpmodel, row[:smc] <= vstorageupperlimit[row[:r],row[:s],row[:y]]))
end

length(ns15_minstoragecapacity) > 0 && logmsg("Created constraint NS15_MinStorageCapacity.", quiet)
# END: NS15_MinStorageCapacity.

# BEGIN: NS16_MaxStorageCapacityInvestment.
ns16_maxstoragecapacityinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select smc.r, smc.s, smc.y, cast(smc.val as real) as smc
from TotalAnnualMaxCapacityInvestmentStorage_def smc")
    push!(ns16_maxstoragecapacityinvestment, @constraint(jumpmodel, vnewstoragecapacity[row[:r],row[:s],row[:y]] <= row[:smc]))
end

length(ns16_maxstoragecapacityinvestment) > 0 && logmsg("Created constraint NS16_MaxStorageCapacityInvestment.", quiet)
# END: NS16_MaxStorageCapacityInvestment.

# BEGIN: NS17_MinStorageCapacityInvestment.
ns17_minstoragecapacityinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select smc.r, smc.s, smc.y, cast(smc.val as real) as smc
from TotalAnnualMinCapacityInvestmentStorage_def smc")
    push!(ns17_minstoragecapacityinvestment, @constraint(jumpmodel, row[:smc] <= vnewstoragecapacity[row[:r],row[:s],row[:y]]))
end

length(ns17_minstoragecapacityinvestment) > 0 && logmsg("Created constraint NS17_MinStorageCapacityInvestment.", quiet)
# END: NS17_MinStorageCapacityInvestment.

# BEGIN: NS18_FullLoadHours.
ns18_fullloadhours::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = s, lastkeys[3] = y
lastvals = Array{Float64, 1}([0.0])  # lastvals[1] = flh
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vnewcapacity sum

# Note: vnewcapacity is in power units; vnewstoragecapacity is in energy units
for row in SQLite.DBInterface.execute(db, "select distinct sf.r as r, sf.s as s, sf.y as y, tfs.t as t, cast(sf.val as real) as flh,
cast(cta.val as real) as cta
from StorageFullLoadHours_def sf, TechnologyFromStorage_def tfs, CapacityToActivityUnit_def cta
where sf.r = tfs.r and sf.s = tfs.s and tfs.val = 1
and tfs.r = cta.r and tfs.t = cta.t
order by sf.r, sf.s, sf.y")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || s != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(ns18_fullloadhours, @constraint(jumpmodel, (sumexps[1]) * lastvals[1] / 8760 == vnewstoragecapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
        lastvals[1] = 0.0
    end

    append!(sumexps[1], vnewcapacity[r,row[:t],y] * row[:cta])

    if !ismissing(row[:flh])
        lastvals[1] = row[:flh]
    end

    lastkeys[1] = r
    lastkeys[2] = s
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(ns18_fullloadhours, @constraint(jumpmodel, (sumexps[1]) * lastvals[1] / 8760 == vnewstoragecapacity[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(ns18_fullloadhours) > 0 && logmsg("Created constraint NS18_FullLoadHours.", quiet)
# END: NS18_FullLoadHours.

# BEGIN: SI4_UndiscountedCapitalInvestmentStorage.
si4_undiscountedcapitalinvestmentstorage::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(ccs.val as real) as ccs
from region r, storage s, year y, CapitalCostStorage_def ccs
where ccs.r = r.val and ccs.s = s.val and ccs.y = y.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si4_undiscountedcapitalinvestmentstorage, @constraint(jumpmodel, row[:ccs] * vnewstoragecapacity[r,s,y] == vcapitalinvestmentstorage[r,s,y]))
end

length(si4_undiscountedcapitalinvestmentstorage) > 0 && logmsg("Created constraint SI4_UndiscountedCapitalInvestmentStorage.", quiet)
# END: SI4_UndiscountedCapitalInvestmentStorage.

# BEGIN: SI5_DiscountingCapitalInvestmentStorage.
si5_discountingcapitalinvestmentstorage::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(dr.val as real) as dr
from region r, storage s, year y, DiscountRate_def dr
where dr.r = r.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si5_discountingcapitalinvestmentstorage, @constraint(jumpmodel, vcapitalinvestmentstorage[r,s,y] / ((1 + row[:dr])^(Meta.parse(y) - Meta.parse(first(syear)))) == vdiscountedcapitalinvestmentstorage[r,s,y]))
end

length(si5_discountingcapitalinvestmentstorage) > 0 && logmsg("Created constraint SI5_DiscountingCapitalInvestmentStorage.", quiet)
# END: SI5_DiscountingCapitalInvestmentStorage.

# BEGIN: SI6_SalvageValueStorageAtEndOfPeriod1.
si6_salvagevaluestorageatendofperiod1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y
from region r, storage s, year y, OperationalLifeStorage_def ols
where ols.r = r.val and ols.s = s.val
and y.val + ols.val - 1 <= " * last(syear))
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si6_salvagevaluestorageatendofperiod1, @constraint(jumpmodel, 0 == vsalvagevaluestorage[r,s,y]))
end

length(si6_salvagevaluestorageatendofperiod1) > 0 && logmsg("Created constraint SI6_SalvageValueStorageAtEndOfPeriod1.", quiet)
# END: SI6_SalvageValueStorageAtEndOfPeriod1.

# BEGIN: SI7_SalvageValueStorageAtEndOfPeriod2.
si7_salvagevaluestorageatendofperiod2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(ols.val as real) as ols
from region r, storage s, year y, DepreciationMethod_def dm, OperationalLifeStorage_def ols, DiscountRate_def dr
where dm.r = r.val and dm.val = 1
and ols.r = r.val and ols.s = s.val
and y.val + ols.val - 1 > " * last(syear) *
" and dr.r = r.val and dr.val = 0
union
select r.val as r, s.val as s, y.val as y, cast(ols.val as real) as ols
from region r, storage s, year y, DepreciationMethod_def dm, OperationalLifeStorage_def ols
where dm.r = r.val and dm.val = 2
and ols.r = r.val and ols.s = s.val
and y.val + ols.val - 1 > " * last(syear))
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si7_salvagevaluestorageatendofperiod2, @constraint(jumpmodel, vcapitalinvestmentstorage[r,s,y] * (1 - (Meta.parse(last(syear)) - Meta.parse(y) + 1) / row[:ols]) == vsalvagevaluestorage[r,s,y]))
end

length(si7_salvagevaluestorageatendofperiod2) > 0 && logmsg("Created constraint SI7_SalvageValueStorageAtEndOfPeriod2.", quiet)
# END: SI7_SalvageValueStorageAtEndOfPeriod2.

# BEGIN: SI8_SalvageValueStorageAtEndOfPeriod3.
si8_salvagevaluestorageatendofperiod3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(dr.val as real) as dr, cast(ols.val as real) as ols
from region r, storage s, year y, DepreciationMethod_def dm, OperationalLifeStorage_def ols, DiscountRate_def dr
where dm.r = r.val and dm.val = 1
and ols.r = r.val and ols.s = s.val
and y.val + ols.val - 1 > " * last(syear) *
" and dr.r = r.val and dr.val > 0")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]
    local dr = row[:dr]

    push!(si8_salvagevaluestorageatendofperiod3, @constraint(jumpmodel, vcapitalinvestmentstorage[r,s,y] * (1 - (((1 + dr)^(Meta.parse(last(syear)) - Meta.parse(y) + 1) - 1) / ((1 + dr)^(row[:ols]) - 1))) == vsalvagevaluestorage[r,s,y]))
end

length(si8_salvagevaluestorageatendofperiod3) > 0 && logmsg("Created constraint SI8_SalvageValueStorageAtEndOfPeriod3.", quiet)
# END: SI8_SalvageValueStorageAtEndOfPeriod3.

# BEGIN: SI9_SalvageValueStorageDiscountedToStartYear.
si9_salvagevaluestoragediscountedtostartyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, s.val as s, y.val as y, cast(dr.val as real) as dr
from region r, storage s, year y, DiscountRate_def dr
where dr.r = r.val")
    local r = row[:r]
    local s = row[:s]
    local y = row[:y]

    push!(si9_salvagevaluestoragediscountedtostartyear, @constraint(jumpmodel, vsalvagevaluestorage[r,s,y] / ((1 + row[:dr])^(Meta.parse(last(syear)) - Meta.parse(first(syear)) + 1)) == vdiscountedsalvagevaluestorage[r,s,y]))
end

length(si9_salvagevaluestoragediscountedtostartyear) > 0 && logmsg("Created constraint SI9_SalvageValueStorageDiscountedToStartYear.", quiet)
# END: SI9_SalvageValueStorageDiscountedToStartYear.

# BEGIN: SI10_TotalDiscountedCostByStorage.
si10_totaldiscountedcostbystorage::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, s, y) in Base.product(sregion, sstorage, syear)
    push!(si10_totaldiscountedcostbystorage, @constraint(jumpmodel, vdiscountedcapitalinvestmentstorage[r,s,y] - vdiscountedsalvagevaluestorage[r,s,y] == vtotaldiscountedstoragecost[r,s,y]))
end

length(si10_totaldiscountedcostbystorage) > 0 && logmsg("Created constraint SI10_TotalDiscountedCostByStorage.", quiet)
# END: SI10_TotalDiscountedCostByStorage.

# BEGIN: CC1_UndiscountedCapitalInvestment.
cc1_undiscountedcapitalinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, cast(cc.val as real) as cc
from region r, technology t, year y, CapitalCost_def cc
where cc.r = r.val and cc.t = t.val and cc.y = y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(cc1_undiscountedcapitalinvestment, @constraint(jumpmodel, row[:cc] * vnewcapacity[r,t,y] == vcapitalinvestment[r,t,y]))
end

length(cc1_undiscountedcapitalinvestment) > 0 && logmsg("Created constraint CC1_UndiscountedCapitalInvestment.", quiet)
# END: CC1_UndiscountedCapitalInvestment.

# BEGIN: CC1Tr_UndiscountedCapitalInvestment.
if transmissionmodeling
    cc1tr_undiscountedcapitalinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select tl.id as tr, y.val as y, cast(tl.CapitalCost as real) as cc from
    TransmissionLine tl, YEAR y
    where tl.CapitalCost is not null")
        local tr = row[:tr]
        local y = row[:y]

        push!(cc1tr_undiscountedcapitalinvestment, @constraint(jumpmodel, row[:cc] * vtransmissionbuilt[tr,y] == vcapitalinvestmenttransmission[tr,y]))
    end

    length(cc1tr_undiscountedcapitalinvestment) > 0 && logmsg("Created constraint CC1Tr_UndiscountedCapitalInvestment.", quiet)
end
# END: CC1Tr_UndiscountedCapitalInvestment.

# BEGIN: CC2_DiscountingCapitalInvestment.
queryrtydr::SQLite.Query = SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, cast(dr.val as real) as dr
from region r, technology t, year y, DiscountRate_def dr
where dr.r = r.val")

cc2_discountingcapitalinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryrtydr
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(cc2_discountingcapitalinvestment, @constraint(jumpmodel, vcapitalinvestment[r,t,y] / ((1 + row[:dr])^(Meta.parse(y) - Meta.parse(first(syear)))) == vdiscountedcapitalinvestment[r,t,y]))
end

SQLite.reset!(queryrtydr)

length(cc2_discountingcapitalinvestment) > 0 && logmsg("Created constraint CC2_DiscountingCapitalInvestment.", quiet)
# END: CC2_DiscountingCapitalInvestment.

# BEGIN: CC2Tr_DiscountingCapitalInvestment.
if transmissionmodeling
    # Note: if a transmission line crosses regional boundaries, costs are assigned to from region (associated with n1)
    querytrydr::SQLite.Query = SQLite.DBInterface.execute(db, "select tl.id as tr, y.val as y, cast(dr.val as real) as dr
	from TransmissionLine tl, NODE n, YEAR y, DiscountRate_def dr
    where tl.n1 = n.val
	and n.r = dr.r")

    cc2tr_discountingcapitalinvestment::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in querytrydr
        local tr = row[:tr]
        local y = row[:y]

        push!(cc2tr_discountingcapitalinvestment, @constraint(jumpmodel,
            vcapitalinvestmenttransmission[tr,y] / ((1 + row[:dr])^(Meta.parse(y) - Meta.parse(first(syear)))) == vdiscountedcapitalinvestmenttransmission[tr,y]))
    end

    SQLite.reset!(querytrydr)

    length(cc2tr_discountingcapitalinvestment) > 0 && logmsg("Created constraint CC2Tr_DiscountingCapitalInvestment.", quiet)
end
# END: CC2Tr_DiscountingCapitalInvestment.

# BEGIN: SV1_SalvageValueAtEndOfPeriod1.
# DepreciationMethod 1 (if discount rate > 0): base salvage value on % of discounted value remaining at end of modeling period.
# DepreciationMethod 2 (or dm 1 if discount rate = 0): base salvage value on % of operational life remaining at end of modeling period.
sv1_salvagevalueatendofperiod1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, cast(cc.val as real) as cc, cast(dr.val as real) as dr,
cast(ol.val as real) as ol
from region r, technology t, year y, DepreciationMethod_def dm, OperationalLife_def ol, DiscountRate_def dr,
CapitalCost_def cc
where dm.r = r.val and dm.val = 1
and ol.r = r.val and ol.t = t.val
and y.val + ol.val - 1 > " * last(syear) *
" and dr.r = r.val and dr.val > 0
and cc.r = r.val and cc.t = t.val and cc.y = y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]
    local dr = row[:dr]

    push!(sv1_salvagevalueatendofperiod1, @constraint(jumpmodel, vsalvagevalue[r,t,y] ==
        row[:cc] * vnewcapacity[r,t,y] * (1 - (((1 + dr)^(Meta.parse(last(syear)) - Meta.parse(y) + 1) - 1) / ((1 + dr)^(row[:ol]) - 1)))))
end

length(sv1_salvagevalueatendofperiod1) > 0 && logmsg("Created constraint SV1_SalvageValueAtEndOfPeriod1.", quiet)
# END: SV1_SalvageValueAtEndOfPeriod1.

# BEGIN: SV1Tr_SalvageValueAtEndOfPeriod1.
if transmissionmodeling
    sv1tr_salvagevalueatendofperiod1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select tl.id as tr, y.val as y, cast(tl.CapitalCost as real) as cc,
	cast(tl.operationallife as real) as ol, cast(dr.val as real) as dr
	from TransmissionLine tl, NODE n, YEAR y, DepreciationMethod_def dm, DiscountRate_def dr
    where tl.CapitalCost is not null
	and tl.n1 = n.val
	and dm.r = n.r
	and dr.r = n.r
	and y.val + tl.operationallife - 1 > " * last(syear) *
	" and (dm.val = 1 and dr.val > 0)")
        local tr = row[:tr]
        local y = row[:y]
        local dr = row[:dr]

        push!(sv1tr_salvagevalueatendofperiod1, @constraint(jumpmodel, vsalvagevaluetransmission[tr,y] ==
            row[:cc] * vtransmissionbuilt[tr,y] * (1 - (((1 + dr)^(Meta.parse(last(syear)) - Meta.parse(y) + 1) - 1) / ((1 + dr)^(row[:ol]) - 1)))))
    end

    length(sv1tr_salvagevalueatendofperiod1) > 0 && logmsg("Created constraint SV1Tr_SalvageValueAtEndOfPeriod1.", quiet)
end
# END: SV1Tr_SalvageValueAtEndOfPeriod1.

# BEGIN: SV2_SalvageValueAtEndOfPeriod2.
sv2_salvagevalueatendofperiod2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, cast(cc.val as real) as cc, cast(ol.val as real) as ol
from region r, technology t, year y, DepreciationMethod_def dm, OperationalLife_def ol, DiscountRate_def dr,
CapitalCost_def cc
where dm.r = r.val and dm.val = 1
and ol.r = r.val and ol.t = t.val
and y.val + ol.val - 1 > " * last(syear) *
" and dr.r = r.val and dr.val = 0
and cc.r = r.val and cc.t = t.val and cc.y = y.val
union
select r.val as r, t.val as t, y.val as y, cast(cc.val as real) as cc, cast(ol.val as real) as ol
from region r, technology t, year y, DepreciationMethod_def dm, OperationalLife_def ol,
CapitalCost_def cc
where dm.r = r.val and dm.val = 2
and ol.r = r.val and ol.t = t.val
and y.val + ol.val - 1 > " * last(syear) *
" and cc.r = r.val and cc.t = t.val and cc.y = y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(sv2_salvagevalueatendofperiod2, @constraint(jumpmodel, vsalvagevalue[r,t,y] ==
        row[:cc] * vnewcapacity[r,t,y] * (1 - (Meta.parse(last(syear)) - Meta.parse(y) + 1) / row[:ol])))
end

length(sv2_salvagevalueatendofperiod2) > 0 && logmsg("Created constraint SV2_SalvageValueAtEndOfPeriod2.", quiet)
# END: SV2_SalvageValueAtEndOfPeriod2.

# BEGIN: SV2Tr_SalvageValueAtEndOfPeriod2.
if transmissionmodeling
    sv2tr_salvagevalueatendofperiod2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select tl.id as tr, y.val as y, cast(tl.CapitalCost as real) as cc,
	cast(tl.operationallife as real) as ol
	from TransmissionLine tl, NODE n, YEAR y, DepreciationMethod_def dm, DiscountRate_def dr
    where tl.CapitalCost is not null
	and tl.n1 = n.val
	and dm.r = n.r
	and dr.r = n.r
	and y.val + tl.operationallife - 1 > " * last(syear) *
	" and ((dm.val = 1 and dr.val = 0) or (dm.val = 2))")
        local tr = row[:tr]
        local y = row[:y]

        push!(sv2tr_salvagevalueatendofperiod2, @constraint(jumpmodel, vsalvagevaluetransmission[tr,y] ==
            row[:cc] * vtransmissionbuilt[tr,y] * (1 - (Meta.parse(last(syear)) - Meta.parse(y) + 1) / row[:ol])))
    end

    length(sv2tr_salvagevalueatendofperiod2) > 0 && logmsg("Created constraint SV2Tr_SalvageValueAtEndOfPeriod2.", quiet)
end
# END: SV2Tr_SalvageValueAtEndOfPeriod2.

# BEGIN: SV3_SalvageValueAtEndOfPeriod3.
sv3_salvagevalueatendofperiod3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y
from region r, technology t, year y, OperationalLife_def ol
where ol.r = r.val and ol.t = t.val
and y.val + ol.val - 1 <= " * last(syear))
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(sv3_salvagevalueatendofperiod3, @constraint(jumpmodel, vsalvagevalue[r,t,y] == 0))
end

length(sv3_salvagevalueatendofperiod3) > 0 && logmsg("Created constraint SV3_SalvageValueAtEndOfPeriod3.", quiet)
# END: SV3_SalvageValueAtEndOfPeriod3.

# BEGIN: SV3Tr_SalvageValueAtEndOfPeriod3.
if transmissionmodeling
    sv3tr_salvagevalueatendofperiod3::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select tl.id as tr, y.val as y
	from TransmissionLine tl, YEAR y
    where tl.CapitalCost is not null
	and y.val + tl.operationallife - 1 <= " * last(syear))
        local tr = row[:tr]
        local y = row[:y]

        push!(sv3tr_salvagevalueatendofperiod3, @constraint(jumpmodel, vsalvagevaluetransmission[tr,y] == 0))
    end

    length(sv3tr_salvagevalueatendofperiod3) > 0 && logmsg("Created constraint SV3Tr_SalvageValueAtEndOfPeriod3.", quiet)
end
# END: SV3Tr_SalvageValueAtEndOfPeriod3.

# BEGIN: SV4_SalvageValueDiscountedToStartYear.
sv4_salvagevaluediscountedtostartyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryrtydr
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(sv4_salvagevaluediscountedtostartyear, @constraint(jumpmodel, vdiscountedsalvagevalue[r,t,y] ==
        vsalvagevalue[r,t,y] / ((1 + row[:dr])^(1 + Meta.parse(last(syear)) - Meta.parse(first(syear))))))
end

SQLite.reset!(queryrtydr)

length(sv4_salvagevaluediscountedtostartyear) > 0 && logmsg("Created constraint SV4_SalvageValueDiscountedToStartYear.", quiet)
# END: SV4_SalvageValueDiscountedToStartYear.

# BEGIN: SV4Tr_SalvageValueDiscountedToStartYear.
if transmissionmodeling
    sv4tr_salvagevaluediscountedtostartyear::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in querytrydr
        local tr = row[:tr]
        local y = row[:y]

        push!(sv4tr_salvagevaluediscountedtostartyear, @constraint(jumpmodel, vdiscountedsalvagevaluetransmission[tr,y] ==
            vsalvagevaluetransmission[tr,y] / ((1 + row[:dr])^(1 + Meta.parse(last(syear)) - Meta.parse(first(syear))))))
    end

    SQLite.reset!(querytrydr)

    length(sv4tr_salvagevaluediscountedtostartyear) > 0 && logmsg("Created constraint SV4Tr_SalvageValueDiscountedToStartYear.", quiet)
end
# END: SV4Tr_SalvageValueDiscountedToStartYear.

# BEGIN: OC1_OperatingCostsVariable.
oc1_operatingcostsvariable::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vtotalannualtechnologyactivitybymode sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, vc.m as m, cast(vc.val as real) as vc
from region r, technology t, year y, VariableCost_def vc
where vc.r = r.val and vc.t = t.val and vc.y = y.val
and vc.val <> 0
order by r.val, t.val, y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(oc1_operatingcostsvariable, @constraint(jumpmodel, sumexps[1] ==
            vannualvariableoperatingcost[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vtotalannualtechnologyactivitybymode[r,t,row[:m],y] * row[:vc])

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(oc1_operatingcostsvariable, @constraint(jumpmodel, sumexps[1] ==
        vannualvariableoperatingcost[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(oc1_operatingcostsvariable) > 0 && logmsg("Created constraint OC1_OperatingCostsVariable.", quiet)
# END: OC1_OperatingCostsVariable.

# BEGIN: OC2_OperatingCostsFixedAnnual.
oc2_operatingcostsfixedannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, y.val as y, cast(fc.val as real) as fc
from region r, technology t, year y, FixedCost_def fc
where fc.r = r.val and fc.t = t.val and fc.y = y.val")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(oc2_operatingcostsfixedannual, @constraint(jumpmodel, vtotalcapacityannual[r,t,y] * row[:fc] == vannualfixedoperatingcost[r,t,y]))
end

length(oc2_operatingcostsfixedannual) > 0 && logmsg("Created constraint OC2_OperatingCostsFixedAnnual.", quiet)
# END: OC2_OperatingCostsFixedAnnual.

# BEGIN: OC3_OperatingCostsTotalAnnual.
oc3_operatingcoststotalannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, t, y) in Base.product(sregion, stechnology, syear)
    push!(oc3_operatingcoststotalannual, @constraint(jumpmodel, vannualfixedoperatingcost[r,t,y] + vannualvariableoperatingcost[r,t,y] == voperatingcost[r,t,y]))
end

length(oc3_operatingcoststotalannual) > 0 && logmsg("Created constraint OC3_OperatingCostsTotalAnnual.", quiet)
# END: OC3_OperatingCostsTotalAnnual.

# BEGIN: OCTr_OperatingCosts.
if transmissionmodeling
    octr_operatingcosts::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,2)  # lastkeys[1] = tr, lastkeys[2] = y
    lastvals = Array{Float64, 1}(undef,1)  # lastvals[1] = fc
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vtransmissionbyline sum

    for row in DataFrames.eachrow(queries["queryvtransmissionbyline"])
        local tr = row[:tr]
        local y = row[:y]
        local vc = ismissing(row[:vc]) ? 0.0 : row[:vc]
        local fc = ismissing(row[:fc]) ? 0.0 : row[:fc]

        if isassigned(lastkeys, 1) && (tr != lastkeys[1] || y != lastkeys[2])
            # Create constraint
            push!(octr_operatingcosts, @constraint(jumpmodel, sumexps[1]
                + vtransmissionexists[lastkeys[1],lastkeys[2]] * lastvals[1] == voperatingcosttransmission[lastkeys[1],lastkeys[2]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vtransmissionbyline[tr,row[:l],row[:f],y] * row[:ys] * row[:tcta] * vc)

        lastkeys[1] = tr
        lastkeys[2] = y
        lastvals[1] = fc
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(octr_operatingcosts, @constraint(jumpmodel, sumexps[1]
            + vtransmissionexists[lastkeys[1],lastkeys[2]] * lastvals[1] == voperatingcosttransmission[lastkeys[1],lastkeys[2]]))
    end

    length(octr_operatingcosts) > 0 && logmsg("Created constraint OCTr_OperatingCosts.", quiet)
end
# END: OCTr_OperatingCosts.

# BEGIN: OC4_DiscountedOperatingCostsTotalAnnual.
oc4_discountedoperatingcoststotalannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryrtydr
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]
    local dr = row[:dr]

    push!(oc4_discountedoperatingcoststotalannual, @constraint(jumpmodel,
        voperatingcost[r,t,y] / ((1 + dr)^(Meta.parse(y) - Meta.parse(first(syear)) + 0.5)) == vdiscountedoperatingcost[r,t,y]))
end

SQLite.reset!(queryrtydr)

length(oc4_discountedoperatingcoststotalannual) > 0 && logmsg("Created constraint OC4_DiscountedOperatingCostsTotalAnnual.", quiet)
# END: OC4_DiscountedOperatingCostsTotalAnnual.

# BEGIN: OC4Tr_DiscountedOperatingCostsTotalAnnual.
if transmissionmodeling
    oc4tr_discountedoperatingcoststotalannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in querytrydr
        local tr = row[:tr]
        local y = row[:y]
        local dr = row[:dr]

        push!(oc4tr_discountedoperatingcoststotalannual, @constraint(jumpmodel,
            voperatingcosttransmission[tr,y] / ((1 + dr)^(Meta.parse(y) - Meta.parse(first(syear)) + 0.5)) == vdiscountedoperatingcosttransmission[tr,y]))
    end

    length(oc4tr_discountedoperatingcoststotalannual) > 0 && logmsg("Created constraint OC4Tr_DiscountedOperatingCostsTotalAnnual.", quiet)
end
# END: OC4Tr_DiscountedOperatingCostsTotalAnnual.

# BEGIN: TDC1_TotalDiscountedCostByTechnology.
tdc1_totaldiscountedcostbytechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, t, y) in Base.product(sregion, stechnology, syear)
    push!(tdc1_totaldiscountedcostbytechnology, @constraint(jumpmodel,
        vdiscountedoperatingcost[r,t,y] + vdiscountedcapitalinvestment[r,t,y]
        + vdiscountedtechnologyemissionspenalty[r,t,y] - vdiscountedsalvagevalue[r,t,y]
        == vtotaldiscountedcostbytechnology[r,t,y]))
end

length(tdc1_totaldiscountedcostbytechnology) > 0 && logmsg("Created constraint TDC1_TotalDiscountedCostByTechnology.", quiet)
# END: TDC1_TotalDiscountedCostByTechnology.

# BEGIN: TDCTr_TotalDiscountedTransmissionCostByRegion.
if transmissionmodeling
    tdctr_totaldiscountedtransmissioncostbyregion::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,2)  # lastkeys[1] = r, lastkeys[2] = y
    sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = costs sum

    for row in SQLite.DBInterface.execute(db, "select n.r as r, tl.id as tr, y.val as y
	from TransmissionLine tl, NODE n, YEAR y
    where tl.n1 = n.val
	order by n.r, y.val")
        local r = row[:r]
        local y = row[:y]
        local tr = row[:tr]

        if isassigned(lastkeys, 1) && (r != lastkeys[1] || y != lastkeys[2])
            # Create constraint
            push!(tdctr_totaldiscountedtransmissioncostbyregion, @constraint(jumpmodel,
                sumexps[1] == vtotaldiscountedtransmissioncostbyregion[lastkeys[1],lastkeys[2]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vdiscountedcapitalinvestmenttransmission[tr,y] - vdiscountedsalvagevaluetransmission[tr,y]
            + vdiscountedoperatingcosttransmission[tr,y])

        lastkeys[1] = r
        lastkeys[2] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(tdctr_totaldiscountedtransmissioncostbyregion, @constraint(jumpmodel,
            sumexps[1] == vtotaldiscountedtransmissioncostbyregion[lastkeys[1],lastkeys[2]]))
    end

    length(tdctr_totaldiscountedtransmissioncostbyregion) > 0 && logmsg("Created constraint TDCTr_TotalDiscountedTransmissionCostByRegion.", quiet)
end
# END: TDCTr_TotalDiscountedTransmissionCostByRegion.

# BEGIN: TDC2_TotalDiscountedCost.
tdc2_totaldiscountedcost::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for (r, y) in Base.product(sregion, syear)
    push!(tdc2_totaldiscountedcost, @constraint(jumpmodel, (length(stechnology) == 0 ? 0 : sum([vtotaldiscountedcostbytechnology[r,t,y] for t = stechnology]))
        + (length(sstorage) == 0 ? 0 : sum([vtotaldiscountedstoragecost[r,s,y] for s = sstorage]))
        + (transmissionmodeling ? vtotaldiscountedtransmissioncostbyregion[r,y] : 0)
        == vtotaldiscountedcost[r,y]))
end

length(tdc2_totaldiscountedcost) > 0 && logmsg("Created constraint TDC2_TotalDiscountedCost.", quiet)
# END: TDC2_TotalDiscountedCost.

# BEGIN: TCC1_TotalAnnualMaxCapacityConstraint.
tcc1_totalannualmaxcapacityconstraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as tmx
from TotalAnnualMaxCapacity_def")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(tcc1_totalannualmaxcapacityconstraint, @constraint(jumpmodel, vtotalcapacityannual[r,t,y] <= row[:tmx]))
end

length(tcc1_totalannualmaxcapacityconstraint) > 0 && logmsg("Created constraint TCC1_TotalAnnualMaxCapacityConstraint.", quiet)
# END: TCC1_TotalAnnualMaxCapacityConstraint.

# BEGIN: TCC2_TotalAnnualMinCapacityConstraint.
tcc2_totalannualmincapacityconstraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as tmn
from TotalAnnualMinCapacity_def
where val > 0")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(tcc2_totalannualmincapacityconstraint, @constraint(jumpmodel, vtotalcapacityannual[r,t,y] >= row[:tmn]))
end

length(tcc2_totalannualmincapacityconstraint) > 0 && logmsg("Created constraint TCC2_TotalAnnualMinCapacityConstraint.", quiet)
# END: TCC2_TotalAnnualMinCapacityConstraint.

# BEGIN: NCC1_TotalAnnualMaxNewCapacityConstraint.
ncc1_totalannualmaxnewcapacityconstraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as tmx
from TotalAnnualMaxCapacityInvestment_def")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(ncc1_totalannualmaxnewcapacityconstraint, @constraint(jumpmodel, vnewcapacity[r,t,y] <= row[:tmx]))
end

length(ncc1_totalannualmaxnewcapacityconstraint) > 0 && logmsg("Created constraint NCC1_TotalAnnualMaxNewCapacityConstraint.", quiet)
# END: NCC1_TotalAnnualMaxNewCapacityConstraint.

# BEGIN: NCC2_TotalAnnualMinNewCapacityConstraint.
ncc2_totalannualminnewcapacityconstraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as tmn
from TotalAnnualMinCapacityInvestment_def
where val > 0")
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    push!(ncc2_totalannualminnewcapacityconstraint, @constraint(jumpmodel, vnewcapacity[r,t,y] >= row[:tmn]))
end

length(ncc2_totalannualminnewcapacityconstraint) > 0 && logmsg("Created constraint NCC2_TotalAnnualMinNewCapacityConstraint.", quiet)
# END: NCC2_TotalAnnualMinNewCapacityConstraint.

# BEGIN: AAC1_TotalAnnualTechnologyActivity.
if (annualactivityupperlimits || annualactivitylowerlimits || modelperiodactivityupperlimits || modelperiodactivitylowerlimits
    || in("vtotaltechnologyannualactivity", varstosavearr))

    aac1_totalannualtechnologyactivity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
    lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = y
    sumexps = Array{AffExpr, 1}([AffExpr()]) # sumexps[1] = vrateoftotalactivity sum

    for row in SQLite.DBInterface.execute(db, "select r.val as r, t.val as t, ys.y as y, ys.l as l, cast(ys.val as real) as ys
    from region r, technology t, YearSplit_def ys
    order by r.val, t.val, ys.y")
        local r = row[:r]
        local t = row[:t]
        local y = row[:y]

        if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || y != lastkeys[3])
            # Create constraint
            push!(aac1_totalannualtechnologyactivity, @constraint(jumpmodel, sumexps[1] ==
                vtotaltechnologyannualactivity[lastkeys[1],lastkeys[2],lastkeys[3]]))
            sumexps[1] = AffExpr()
        end

        append!(sumexps[1], vrateoftotalactivity[r,t,row[:l],y] * row[:ys])

        lastkeys[1] = r
        lastkeys[2] = t
        lastkeys[3] = y
    end

    # Create last constraint
    if isassigned(lastkeys, 1)
        push!(aac1_totalannualtechnologyactivity, @constraint(jumpmodel, sumexps[1] ==
            vtotaltechnologyannualactivity[lastkeys[1],lastkeys[2],lastkeys[3]]))
    end

    length(aac1_totalannualtechnologyactivity) > 0 && logmsg("Created constraint AAC1_TotalAnnualTechnologyActivity.", quiet)
end
# END: AAC1_TotalAnnualTechnologyActivity.

# BEGIN: AAC2_TotalAnnualTechnologyActivityUpperLimit.
if annualactivityupperlimits
    aac2_totalannualtechnologyactivityupperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select r, t, y, cast(val as real) as amx
    from TotalTechnologyAnnualActivityUpperLimit_def")
        local r = row[:r]
        local t = row[:t]
        local y = row[:y]

        push!(aac2_totalannualtechnologyactivityupperlimit, @constraint(jumpmodel, vtotaltechnologyannualactivity[r,t,y] <= row[:amx]))
    end

    length(aac2_totalannualtechnologyactivityupperlimit) > 0 && logmsg("Created constraint AAC2_TotalAnnualTechnologyActivityUpperLimit.", quiet)
end
# END: AAC2_TotalAnnualTechnologyActivityUpperLimit.

# BEGIN: AAC3_TotalAnnualTechnologyActivityLowerLimit.
if annualactivitylowerlimits
    aac3_totalannualtechnologyactivitylowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in queryannualactivitylowerlimit
        local r = row[:r]
        local t = row[:t]
        local y = row[:y]

        push!(aac3_totalannualtechnologyactivitylowerlimit, @constraint(jumpmodel, vtotaltechnologyannualactivity[r,t,y] >= row[:amn]))
    end

    length(aac3_totalannualtechnologyactivitylowerlimit) > 0 && logmsg("Created constraint AAC3_TotalAnnualTechnologyActivityLowerLimit.", quiet)
end
# END: AAC3_TotalAnnualTechnologyActivityLowerLimit.

# BEGIN: TAC1_TotalModelHorizonTechnologyActivity.
if modelperiodactivitylowerlimits || modelperiodactivityupperlimits || in("vtotaltechnologymodelperiodactivity", varstosavearr)
    tac1_totalmodelhorizontechnologyactivity::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for (r, t) in Base.product(sregion, stechnology)
        push!(tac1_totalmodelhorizontechnologyactivity, @constraint(jumpmodel, sum([vtotaltechnologyannualactivity[r,t,y] for y = syear]) == vtotaltechnologymodelperiodactivity[r,t]))
    end

    length(tac1_totalmodelhorizontechnologyactivity) > 0 && logmsg("Created constraint TAC1_TotalModelHorizonTechnologyActivity.", quiet)
end
# END: TAC1_TotalModelHorizonTechnologyActivity.

# BEGIN: TAC2_TotalModelHorizonTechnologyActivityUpperLimit.
if modelperiodactivityupperlimits
    tac2_totalmodelhorizontechnologyactivityupperlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in SQLite.DBInterface.execute(db, "select r, t, cast(val as real) as mmx
    from TotalTechnologyModelPeriodActivityUpperLimit_def")
        local r = row[:r]
        local t = row[:t]

        push!(tac2_totalmodelhorizontechnologyactivityupperlimit, @constraint(jumpmodel, vtotaltechnologymodelperiodactivity[r,t] <= row[:mmx]))
    end

    length(tac2_totalmodelhorizontechnologyactivityupperlimit) > 0 && logmsg("Created constraint TAC2_TotalModelHorizonTechnologyActivityUpperLimit.", quiet)
end
# END: TAC2_TotalModelHorizonTechnologyActivityUpperLimit.

# BEGIN: TAC3_TotalModelHorizonTechnologyActivityLowerLimit.
if modelperiodactivitylowerlimits
    tac3_totalmodelhorizontechnologyactivitylowerlimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in querymodelperiodactivitylowerlimit
        local r = row[:r]
        local t = row[:t]

        push!(tac3_totalmodelhorizontechnologyactivitylowerlimit, @constraint(jumpmodel, vtotaltechnologymodelperiodactivity[r,t] >= row[:mmn]))
    end

    length(tac3_totalmodelhorizontechnologyactivitylowerlimit) > 0 && logmsg("Created constraint TAC3_TotalModelHorizonTechnologyActivityLowerLimit.", quiet)
end
# END: TAC3_TotalModelHorizonTechnologyActivityLowerLimit.

# BEGIN: RM1_ReserveMargin_TechnologiesIncluded_In_Activity_Units.
rm1_reservemargin_technologiesincluded_in_activity_units::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,2)  # lastkeys[1] = r, lastkeys[2] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vtotalcapacityannual sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, y.val as y, rmt.t as t, cast(rmt.val as real) as rmt, cast(cau.val as real) as cau
from region r, year y, ReserveMarginTagTechnology_def rmt, CapacityToActivityUnit_def cau
where rmt.r = r.val and rmt.t = cau.t and rmt.y = y.val and rmt.val <> 0
and cau.r = r.val and cau.val <> 0
order by r.val, y.val")
    local r = row[:r]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || y != lastkeys[2])
        # Create constraint
        push!(rm1_reservemargin_technologiesincluded_in_activity_units, @constraint(jumpmodel, sumexps[1] ==
            vtotalcapacityinreservemargin[lastkeys[1],lastkeys[2]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vtotalcapacityannual[r,row[:t],y] * row[:rmt] * row[:cau])

    lastkeys[1] = r
    lastkeys[2] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(rm1_reservemargin_technologiesincluded_in_activity_units, @constraint(jumpmodel, sumexps[1] ==
        vtotalcapacityinreservemargin[lastkeys[1],lastkeys[2]]))
end

length(rm1_reservemargin_technologiesincluded_in_activity_units) > 0 && logmsg("Created constraint RM1_ReserveMargin_TechnologiesIncluded_In_Activity_Units.", quiet)
# END: RM1_ReserveMargin_TechnologiesIncluded_In_Activity_Units.

# BEGIN: RM2_ReserveMargin_FuelsIncluded.
rm2_reservemargin_fuelsincluded::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = l, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])
# sumexps[1] = vrateofproduction sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, l.val as l, y.val as y, rmf.f as f, cast(rmf.val as real) as rmf
from region r, timeslice l, year y, ReserveMarginTagFuel_def rmf
where rmf.r = r.val and rmf.y = y.val and rmf.val <> 0
order by r.val, l.val, y.val")
    local r = row[:r]
    local l = row[:l]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || l != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(rm2_reservemargin_fuelsincluded, @constraint(jumpmodel, sumexps[1] ==
            vdemandneedingreservemargin[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofproduction[r,l,row[:f],y] * row[:rmf])

    lastkeys[1] = r
    lastkeys[2] = l
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(rm2_reservemargin_fuelsincluded, @constraint(jumpmodel, sumexps[1] ==
        vdemandneedingreservemargin[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(rm2_reservemargin_fuelsincluded) > 0 && logmsg("Created constraint RM2_ReserveMargin_FuelsIncluded.", quiet)
# END: RM2_ReserveMargin_FuelsIncluded.

# BEGIN: RM3_ReserveMargin_Constraint.
rm3_reservemargin_constraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, l.val as l, y.val as y, cast(rm.val as real) as rm
from region r, timeslice l, year y, ReserveMargin_def rm
where rm.r = r.val and rm.y = y.val")
    local r = row[:r]
    local l = row[:l]
    local y = row[:y]

    push!(rm3_reservemargin_constraint, @constraint(jumpmodel, vdemandneedingreservemargin[r,l,y] * row[:rm] <= vtotalcapacityinreservemargin[r,y]))
end

length(rm3_reservemargin_constraint) > 0 && logmsg("Created constraint RM3_ReserveMargin_Constraint.", quiet)
# END: RM3_ReserveMargin_Constraint.

# BEGIN: RE1_FuelProductionByTechnologyAnnual.
re1_fuelproductionbytechnologyannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = f, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vproductionbytechnologynn-equivalent sum

for row in DataFrames.eachrow(queries["queryvproductionbytechnologyannual"])
    local r = row[:r]
    local t = row[:t]
    local f = row[:f]
    local y = row[:y]
    local n = row[:n]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(re1_fuelproductionbytechnologyannual, @constraint(jumpmodel, sumexps[1] == vproductionbytechnologyannual[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    if ismissing(n)
        append!(sumexps[1], vrateofproductionbytechnologynn[r,row[:l],t,f,y] * row[:ys])
    else
        append!(sumexps[1], vrateofproductionbytechnologynodal[n,row[:l],t,f,y] * row[:ys])
    end

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = f
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(re1_fuelproductionbytechnologyannual, @constraint(jumpmodel, sumexps[1] == vproductionbytechnologyannual[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(re1_fuelproductionbytechnologyannual) > 0 && logmsg("Created constraint RE1_FuelProductionByTechnologyAnnual.", quiet)
# END: RE1_FuelProductionByTechnologyAnnual.

# BEGIN: FuelUseByTechnologyAnnual.
fuelusebytechnologyannual::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = f, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vusebytechnologynn-equivalent sum

for row in DataFrames.eachrow(queries["queryvusebytechnologyannual"])
    local r = row[:r]
    local t = row[:t]
    local f = row[:f]
    local y = row[:y]
    local n = row[:n]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || f != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(fuelusebytechnologyannual, @constraint(jumpmodel, sumexps[1] == vusebytechnologyannual[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    if ismissing(n)
        append!(sumexps[1], vrateofusebytechnologynn[r,row[:l],t,f,y] * row[:ys])
    else
        append!(sumexps[1], vrateofusebytechnologynodal[n,row[:l],t,f,y] * row[:ys])
    end

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = f
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(fuelusebytechnologyannual, @constraint(jumpmodel, sumexps[1] == vusebytechnologyannual[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(fuelusebytechnologyannual) > 0 && logmsg("Created constraint FuelUseByTechnologyAnnual.", quiet)
# END: FuelUseByTechnologyAnnual.

# BEGIN: RE2_TechIncluded.
re2_techincluded::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,2)  # lastkeys[1] = r, lastkeys[2] = y
sumexps = Array{AffExpr, 1}([AffExpr()]) # sumexps[1] = vproductionbytechnologyannual sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, y.val as y, oar.t as t, oar.f as f, cast(ret.val as real) as ret
from REGION r, YEAR y, RETagTechnology_def ret,
(select distinct r, t, f, y
from OutputActivityRatio_def
where val <> 0) oar
where oar.r = r.val and oar.t = ret.t and oar.y = y.val
and ret.r = r.val and ret.y = y.val and ret.val <> 0
order by r.val, y.val")
    local r = row[:r]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || y != lastkeys[2])
        # Create constraint
        push!(re2_techincluded, @constraint(jumpmodel, sumexps[1] ==
            vtotalreproductionannual[lastkeys[1],lastkeys[2]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vproductionbytechnologyannual[r,row[:t],row[:f],y] * row[:ret])

    lastkeys[1] = r
    lastkeys[2] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(re2_techincluded, @constraint(jumpmodel, sumexps[1] ==
        vtotalreproductionannual[lastkeys[1],lastkeys[2]]))
end

length(re2_techincluded) > 0 && logmsg("Created constraint RE2_TechIncluded.", quiet)
# END: RE2_TechIncluded.

# BEGIN: RE3_FuelIncluded.
re3_fuelincluded::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vrateofproduction sum

for row in SQLite.DBInterface.execute(db, "select r.val as r, y.val as y, ys.l as l, rtf.f as f, cast(ys.val as real) as ys,
cast(rtf.val as real) as rtf
from REGION r, YEAR y, YearSplit_def ys, RETagFuel_def rtf
where ys.y = y.val and ys.val <> 0
and rtf.r = r.val and rtf.y = y.val and rtf.val <> 0
order by r.val, y.val")
    local r = row[:r]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || y != lastkeys[2])
        # Create constraint
        push!(re3_fuelincluded, @constraint(jumpmodel, sumexps[1] ==
            vretotalproductionoftargetfuelannual[lastkeys[1],lastkeys[2]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vrateofproduction[r,row[:l],row[:f],y] * row[:ys] * row[:rtf])

    lastkeys[1] = r
    lastkeys[2] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(re3_fuelincluded, @constraint(jumpmodel, sumexps[1] ==
        vretotalproductionoftargetfuelannual[lastkeys[1],lastkeys[2]]))
end

length(re3_fuelincluded) > 0 && logmsg("Created constraint RE3_FuelIncluded.", quiet)
# END: RE3_FuelIncluded.

# BEGIN: RE4_EnergyConstraint.
re4_energyconstraint::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select ry.r as r, ry.y as y, cast(rmp.val as real) as rmp
from
(select distinct r.val as r, y.val as y
from REGION r, TECHNOLOGY t, FUEL f, YEAR y, OutputActivityRatio_def oar, RETagTechnology_def ret
where oar.r = r.val and oar.t = t.val and oar.f = f.val and oar.y = y.val and oar.val <> 0
and ret.r = r.val and ret.t = t.val and ret.y = y.val and ret.val <> 0
intersect
select distinct r.val as r, y.val as y
from REGION r, YEAR y, TIMESLICE l, FUEL f, YearSplit_def ys, RETagFuel_def rtf
where ys.l = l.val and ys.y = y.val
and rtf.r = r.val and rtf.f = f.val and rtf.y = y.val and rtf.val <> 0) ry, REMinProductionTarget_def rmp
where rmp.r = ry.r and rmp.y = ry.y")
    local r = row[:r]
    local y = row[:y]

    push!(re4_energyconstraint, @constraint(jumpmodel, row[:rmp] * vretotalproductionoftargetfuelannual[r,y] <= vtotalreproductionannual[r,y]))
end

length(re4_energyconstraint) > 0 && logmsg("Created constraint RE4_EnergyConstraint.", quiet)
# END: RE4_EnergyConstraint.

# Omitting RE5_FuelUseByTechnologyAnnual because it's just an identity that's not used elsewhere in model

# BEGIN: E1_AnnualEmissionProductionByMode.
queryvannualtechnologyemissionbymode::SQLite.Query = SQLite.DBInterface.execute(db,
"select r, t, e, y, m, cast(val as real) as ear
from EmissionActivityRatio_def ear
order by r, t, e, y")

if in("vannualtechnologyemissionbymode", varstosavearr)
    e1_annualemissionproductionbymode::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in queryvannualtechnologyemissionbymode
        local r = row[:r]
        local t = row[:t]
        local e = row[:e]
        local m = row[:m]
        local y = row[:y]

        push!(e1_annualemissionproductionbymode, @constraint(jumpmodel, row[:ear] * vtotalannualtechnologyactivitybymode[r,t,m,y] == vannualtechnologyemissionbymode[r,t,e,m,y]))
    end

    SQLite.reset!(queryvannualtechnologyemissionbymode)

    length(e1_annualemissionproductionbymode) > 0 && logmsg("Created constraint E1_AnnualEmissionProductionByMode.", quiet)
end
# END: E1_AnnualEmissionProductionByMode.

# BEGIN: E2_AnnualEmissionProduction.
e2_annualemissionproduction::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,4)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = e, lastkeys[4] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vannualtechnologyemissionbymode-equivalent sum

for row in queryvannualtechnologyemissionbymode
    local r = row[:r]
    local t = row[:t]
    local e = row[:e]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || e != lastkeys[3] || y != lastkeys[4])
        # Create constraint
        push!(e2_annualemissionproduction, @constraint(jumpmodel, sumexps[1] ==
            vannualtechnologyemission[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], row[:ear] * vtotalannualtechnologyactivitybymode[r,t,row[:m],y])

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = e
    lastkeys[4] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(e2_annualemissionproduction, @constraint(jumpmodel, sumexps[1] ==
        vannualtechnologyemission[lastkeys[1],lastkeys[2],lastkeys[3],lastkeys[4]]))
end

length(e2_annualemissionproduction) > 0 && logmsg("Created constraint E2_AnnualEmissionProduction.", quiet)
# END: E2_AnnualEmissionProduction.

# BEGIN: E3_EmissionsPenaltyByTechAndEmission.
queryvannualtechnologyemissionpenaltybyemission::SQLite.Query = SQLite.DBInterface.execute(db,
"select distinct ear.r as r, ear.t as t, ear.e as e, ear.y as y, cast(ep.val as real) as ep
from EmissionActivityRatio_def ear, EmissionsPenalty_def ep
where ep.r = ear.r and ep.e = ear.e and ep.y = ear.y
and ep.val <> 0
order by ear.r, ear.t, ear.y")

if in("vannualtechnologyemissionpenaltybyemission", varstosavearr)
    e3_emissionspenaltybytechandemission::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

    for row in queryvannualtechnologyemissionpenaltybyemission
        local r = row[:r]
        local t = row[:t]
        local e = row[:e]
        local y = row[:y]

        push!(e3_emissionspenaltybytechandemission, @constraint(jumpmodel, vannualtechnologyemission[r,t,e,y] * row[:ep] == vannualtechnologyemissionpenaltybyemission[r,t,e,y]))
    end

    SQLite.reset!(queryvannualtechnologyemissionpenaltybyemission)

    length(e3_emissionspenaltybytechandemission) > 0 && logmsg("Created constraint E3_EmissionsPenaltyByTechAndEmission.", quiet)
end
# END: E3_EmissionsPenaltyByTechAndEmission.

# BEGIN: E4_EmissionsPenaltyByTechnology.
e4_emissionspenaltybytechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = t, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])
# sumexps[1] = vannualtechnologyemissionpenaltybyemission-equivalent sum

for row in queryvannualtechnologyemissionpenaltybyemission
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || t != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(e4_emissionspenaltybytechnology, @constraint(jumpmodel, sumexps[1] ==
            vannualtechnologyemissionspenalty[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vannualtechnologyemission[r,t,row[:e],y] * row[:ep])

    lastkeys[1] = r
    lastkeys[2] = t
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(e4_emissionspenaltybytechnology, @constraint(jumpmodel, sumexps[1] ==
        vannualtechnologyemissionspenalty[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(e4_emissionspenaltybytechnology) > 0 && logmsg("Created constraint E4_EmissionsPenaltyByTechnology.", quiet)
# END: E4_EmissionsPenaltyByTechnology.

# BEGIN: E5_DiscountedEmissionsPenaltyByTechnology.
e5_discountedemissionspenaltybytechnology::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in queryrtydr
    local r = row[:r]
    local t = row[:t]
    local y = row[:y]
    local dr = row[:dr]

    push!(e5_discountedemissionspenaltybytechnology, @constraint(jumpmodel, vannualtechnologyemissionspenalty[r,t,y] / ((1 + dr)^(Meta.parse(y) - Meta.parse(first(syear)) + 0.5)) == vdiscountedtechnologyemissionspenalty[r,t,y]))
end

length(e5_discountedemissionspenaltybytechnology) > 0 && logmsg("Created constraint E5_DiscountedEmissionsPenaltyByTechnology.", quiet)
# END: E5_DiscountedEmissionsPenaltyByTechnology.

# BEGIN: E6_EmissionsAccounting1.
e6_emissionsaccounting1::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()
lastkeys = Array{String, 1}(undef,3)  # lastkeys[1] = r, lastkeys[2] = e, lastkeys[3] = y
sumexps = Array{AffExpr, 1}([AffExpr()])  # sumexps[1] = vannualtechnologyemission sum

for row in SQLite.DBInterface.execute(db, "select distinct r, e, y, t
from EmissionActivityRatio_def ear
order by r, e, y")
    local r = row[:r]
    local e = row[:e]
    local y = row[:y]

    if isassigned(lastkeys, 1) && (r != lastkeys[1] || e != lastkeys[2] || y != lastkeys[3])
        # Create constraint
        push!(e6_emissionsaccounting1, @constraint(jumpmodel, sumexps[1] ==
            vannualemissions[lastkeys[1],lastkeys[2],lastkeys[3]]))
        sumexps[1] = AffExpr()
    end

    append!(sumexps[1], vannualtechnologyemission[r,row[:t],e,y])

    lastkeys[1] = r
    lastkeys[2] = e
    lastkeys[3] = y
end

# Create last constraint
if isassigned(lastkeys, 1)
    push!(e6_emissionsaccounting1, @constraint(jumpmodel, sumexps[1] ==
        vannualemissions[lastkeys[1],lastkeys[2],lastkeys[3]]))
end

length(e6_emissionsaccounting1) > 0 && logmsg("Created constraint E6_EmissionsAccounting1.", quiet)
# END: E6_EmissionsAccounting1.

# BEGIN: E7_EmissionsAccounting2.
e7_emissionsaccounting2::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, e.val as e, cast(mpe.val as real) as mpe
from region r, emission e
left join ModelPeriodExogenousEmission_def mpe on mpe.r = r.val and mpe.e = e.val")
    local r = row[:r]
    local e = row[:e]
    local mpe = ismissing(row[:mpe]) ? 0 : row[:mpe]

    push!(e7_emissionsaccounting2, @constraint(jumpmodel, sum([vannualemissions[r,e,y] for y = syear]) == vmodelperiodemissions[r,e] - mpe))
end

length(e7_emissionsaccounting2) > 0 && logmsg("Created constraint E7_EmissionsAccounting2.", quiet)
# END: E7_EmissionsAccounting2.

# BEGIN: E8_AnnualEmissionsLimit.
e8_annualemissionslimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, e.val as e, y.val as y, cast(aee.val as real) as aee, cast(ael.val as real) as ael
from region r, emission e, year y, AnnualEmissionLimit_def ael
left join AnnualExogenousEmission_def aee on aee.r = r.val and aee.e = e.val and aee.y = y.val
where ael.r = r.val and ael.e = e.val and ael.y = y.val")
    local r = row[:r]
    local e = row[:e]
    local y = row[:y]
    local aee = ismissing(row[:aee]) ? 0 : row[:aee]

    push!(e8_annualemissionslimit, @constraint(jumpmodel, vannualemissions[r,e,y] + aee <= row[:ael]))
end

length(e8_annualemissionslimit) > 0 && logmsg("Created constraint E8_AnnualEmissionsLimit.", quiet)
# END: E8_AnnualEmissionsLimit.

# BEGIN: E9_ModelPeriodEmissionsLimit.
e9_modelperiodemissionslimit::Array{ConstraintRef, 1} = Array{ConstraintRef, 1}()

for row in SQLite.DBInterface.execute(db, "select r.val as r, e.val as e, cast(mpl.val as real) as mpl
from region r, emission e, ModelPeriodEmissionLimit_def mpl
where mpl.r = r.val and mpl.e = e.val")
    local r = row[:r]
    local e = row[:e]

    push!(e9_modelperiodemissionslimit, @constraint(jumpmodel, vmodelperiodemissions[r,e] <= row[:mpl]))
end

length(e9_modelperiodemissionslimit) > 0 && logmsg("Created constraint E9_ModelPeriodEmissionsLimit.", quiet)
# END: E9_ModelPeriodEmissionsLimit.

# BEGIN: Perform customconstraints include.
if configfile != nothing && haskey(configfile, "includes", "customconstraints")
    try
        include(normpath(joinpath(pwd(), retrieve(configfile, "includes", "customconstraints"))))
        logmsg("Performed customconstraints include.", quiet)
    catch e
        logmsg("Could not perform customconstraints include. Error message: " * sprint(showerror, e) * ". Continuing with NEMO.", quiet)
    end
end
# END: Perform customconstraints include.

# END: Define model constraints.

# BEGIN: Define model objective.
@objective(jumpmodel, Min, sum([vtotaldiscountedcost[r,y] for r = sregion, y = syear]))
logmsg("Defined model objective.", quiet)
# END: Define model objective.

# Solve model
status::Symbol = solve(jumpmodel)
solvedtm::DateTime = now()  # Date/time of last solve operation
solvedtmstr::String = Dates.format(solvedtm, "yyyy-mm-dd HH:MM:SS.sss")  # solvedtm as a formatted string
logmsg("Solved model. Solver status = " * string(status) * ".", quiet, solvedtm)

# BEGIN: Save results to database.
savevarresults(varstosavearr, modelvarindices, db, solvedtmstr, reportzeros, quiet)
logmsg("Finished saving results to database.", quiet)
# END: Save results to database.

# Drop temporary tables
drop_temp_tables(db)
logmsg("Dropped temporary tables.", quiet)

logmsg("Finished scenario calculation.")
return status
end  # calculatescenario_main()
