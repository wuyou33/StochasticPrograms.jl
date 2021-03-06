"""
    SerialExecution

Functor object for using serial execution in a progressive-hedging algorithm. Create by supplying a [`Serial`](@ref) object through `execution` in the `ProgressiveHedgingSolver` factory function and then pass to a `StochasticPrograms.jl` model.

"""
struct SerialExecution{T <: AbstractFloat,
                       A <: AbstractVector,
                       S <: LQSolver,
                       PT <: PenaltyTerm} <: AbstractExecution
    subproblems::Vector{SubProblem{T,A,S,PT}}

    function SerialExecution(::Type{T}, ::Type{A}, ::Type{S}, ::Type{PT}) where {T <: AbstractFloat, A <: AbstractVector, S <: LQSolver, PT <: PenaltyTerm}
        return new{T,A,S,PT}(Vector{SubProblem{T,A,S,PT}}())
    end
end

function initialize_subproblems!(ph::AbstractProgressiveHedgingSolver, subsolver::QPSolver, penaltyterm::PenaltyTerm, execution::SerialExecution)
    for i = 1:ph.nscenarios
        push!(execution.subproblems,SubProblem(WS(ph.stochasticprogram, scenario(ph.stochasticprogram,i); solver = subsolver),
                                               i,
                                               probability(ph.stochasticprogram,i),
                                               decision_length(ph.stochasticprogram),
                                               subsolver,
                                               copy(penaltyterm)))
    end
    update_iterate!(ph)
    return ph
end

function resolve_subproblems!(ph::AbstractProgressiveHedgingSolver, execution::SerialExecution{T,A}) where {T <: AbstractFloat, A <: AbstractVector}
    Qs = A(undef, length(execution.subproblems))
    # Update subproblems
    reformulate_subproblems!(execution.subproblems, ph.ξ, penalty(ph))
    # Solve sub problems
    for (i, subproblem) ∈ enumerate(execution.subproblems)
        Qs[i] = subproblem(ph.ξ)
    end
    # Return current objective value
    return sum(Qs)
end

function update_iterate!(ph::AbstractProgressiveHedgingSolver, execution::SerialExecution)
    # Update the estimate
    ξ_prev = copy(ph.ξ)
    ph.ξ[:] = sum([subproblem.π*subproblem.x for subproblem in execution.subproblems])
    # Update δ₁
    ph.data.δ₁ = norm(ph.ξ-ξ_prev, 2)^2
    return nothing
end

function update_subproblems!(ph::AbstractProgressiveHedgingSolver, execution::SerialExecution)
    # Update dual prices
    update_subproblems!(execution.subproblems, ph.ξ, penalty(ph))
    return nothing
end

function update_dual_gap!(ph::AbstractProgressiveHedgingSolver, execution::SerialExecution)
    # Update δ₂
    ph.data.δ₂ = sum([s.π*norm(s.x-ph.ξ,2)^2 for s in execution.subproblems])
    return nothing
end

function calculate_objective_value(ph::AbstractProgressiveHedgingSolver, execution::SerialExecution)
    return sum([get_objective_value(s) for s in execution.subproblems])
end

function fill_first_stage!(ph::AbstractProgressiveHedgingSolver, stochasticprogram::StochasticProgram, nrows::Integer, ncols::Integer, execution::SerialExecution)
    subproblem = execution.subproblems[1]
    μ = try
        MPB.getreducedcosts(subproblem.solver.lqmodel)[1:ncols]
    catch
        fill(NaN, ncols)
    end
    StochasticPrograms.set_first_stage_redcosts!(stochasticprogram, μ)
    λ = try
        MPB.getconstrduals(subproblem.solver.lqmodel)[1:nrows]
    catch
        fill(NaN, nrows)
    end
    StochasticPrograms.set_first_stage_duals!(stochasticprogram, λ)
    return nothing
end

function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.ScenarioProblems, nrows::Integer, ncols::Integer, execution::SerialExecution)
    for (i, submodel) in enumerate(scenarioproblems.problems)
        fill_submodel!(submodel, execution.subproblems[i], nrows, ncols)
    end
    return nothing
end

function fill_submodels!(ph::AbstractProgressiveHedgingSolver, scenarioproblems::StochasticPrograms.DScenarioProblems, nrows::Integer, ncols::Integer, execution::SerialExecution)
    j = 0
    @sync begin
        for w in workers()
            n = remotecall_fetch((sp)->length(fetch(sp).problems), w, scenarioproblems[w-1])
            for i in 1:n
                k = i+j
                @async remotecall_fetch((sp,i,x,μ,λ,nrows,ncols) -> fill_submodel!(fetch(sp).problems[i],x,μ,λ,nrows,ncols),
                                        w,
                                        scenarioproblems[w-1],
                                        i,
                                        get_solution(execution.subproblems[k])...,
                                        nrows,
                                        ncols)
            end
            j += n
        end
    end
    return nothing
end
# API
# ------------------------------------------------------------
function (execution::Serial)(::Type{T}, ::Type{A}, ::Type{S}, ::Type{PT}) where {T <: AbstractFloat, A <: AbstractVector, S <: LQSolver, PT <: PenaltyTerm}
    return SerialExecution(T,A,S,PT)
end

function str(::Serial)
    return "serial execution"
end
