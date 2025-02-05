# TODO: Make `UniformSampling` and `Prior` algs + just use `Sampler`
# That would let us use all defaults for Sampler, combine it with other samplers etc.
"""
    SampleFromUniform

Sampling algorithm that samples unobserved random variables from a uniform distribution.

# References

[Stan reference manual](https://mc-stan.org/docs/2_28/reference-manual/initialization.html#random-initial-values)
"""
struct SampleFromUniform <: AbstractSampler end

"""
    SampleFromPrior

Sampling algorithm that samples unobserved random variables from their prior distribution.
"""
struct SampleFromPrior <: AbstractSampler end

getspace(::Union{SampleFromPrior,SampleFromUniform}) = ()

# Initializations.
init(rng, dist, ::SampleFromPrior) = rand(rng, dist)
function init(rng, dist, ::SampleFromUniform)
    return istransformable(dist) ? inittrans(rng, dist) : rand(rng, dist)
end

init(rng, dist, ::SampleFromPrior, n::Int) = rand(rng, dist, n)
function init(rng, dist, ::SampleFromUniform, n::Int)
    return istransformable(dist) ? inittrans(rng, dist, n) : rand(rng, dist, n)
end

"""
    Sampler{T}

Generic sampler type for inference algorithms of type `T` in DynamicPPL.

`Sampler` should implement the AbstractMCMC interface, and in particular
`AbstractMCMC.step`. A default implementation of the initial sampling step is
provided that supports resuming sampling from a previous state and setting initial
parameter values. It requires to overload [`loadstate`](@ref) and [`initialstep`](@ref)
for loading previous states and actually performing the initial sampling step,
respectively. Additionally, sometimes one might want to implement [`initialsampler`](@ref)
that specifies how the initial parameter values are sampled if they are not provided.
By default, values are sampled from the prior.
"""
struct Sampler{T} <: AbstractSampler
    alg::T
    selector::Selector # Can we remove it?
    # TODO: add space such that we can integrate existing external samplers in DynamicPPL
end
Sampler(alg) = Sampler(alg, Selector())
Sampler(alg, model::Model) = Sampler(alg, model, Selector())
Sampler(alg, model::Model, s::Selector) = Sampler(alg, s)

# AbstractMCMC interface for SampleFromUniform and SampleFromPrior
function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::Model,
    sampler::Union{SampleFromUniform,SampleFromPrior},
    state=nothing;
    kwargs...,
)
    vi = VarInfo()
    model(rng, vi, sampler)
    return vi, nothing
end

function default_varinfo(rng::Random.AbstractRNG, model::Model, sampler::AbstractSampler)
    return default_varinfo(rng, model, sampler, DefaultContext())
end
function default_varinfo(
    rng::Random.AbstractRNG,
    model::Model,
    sampler::AbstractSampler,
    context::AbstractContext,
)
    init_sampler = initialsampler(sampler)
    return VarInfo(rng, model, init_sampler, context)
end

# initial step: general interface for resuming and
function AbstractMCMC.step(
    rng::Random.AbstractRNG,
    model::Model,
    spl::Sampler;
    resume_from=nothing,
    init_params=nothing,
    kwargs...,
)
    if resume_from !== nothing
        state = loadstate(resume_from)
        return AbstractMCMC.step(rng, model, spl, state; kwargs...)
    end

    # Sample initial values.
    vi = default_varinfo(rng, model, spl)

    # Update the parameters if provided.
    if init_params !== nothing
        vi = initialize_parameters!!(vi, init_params, spl, model)

        # Update joint log probability.
        # This is a quick fix for https://github.com/TuringLang/Turing.jl/issues/1588
        # and https://github.com/TuringLang/Turing.jl/issues/1563
        # to avoid that existing variables are resampled
        vi = last(evaluate!!(model, vi, DefaultContext()))
    end

    return initialstep(rng, model, spl, vi; init_params=init_params, kwargs...)
end

"""
    loadstate(data)

Load sampler state from `data`.
"""
function loadstate end

"""
    initialsampler(sampler::Sampler)

Return the sampler that is used for generating the initial parameters when sampling with
`sampler`.

By default, it returns an instance of [`SampleFromPrior`](@ref).
"""
initialsampler(spl::Sampler) = SampleFromPrior()

function initialize_parameters!!(
    vi::AbstractVarInfo, init_params, spl::Sampler, model::Model
)
    @debug "Using passed-in initial variable values" init_params

    # Flatten parameters.
    init_theta = mapreduce(vcat, init_params) do x
        vec([x;])
    end

    # Get all values.
    linked = islinked(vi, spl)
    if linked
        vi = invlink!!(vi, spl, model)
    end
    theta = vi[spl]
    length(theta) == length(init_theta) ||
        error("Provided initial value doesn't match the dimension of the model, if using MCMCDistributed(), pass init_params as a list of length n_chains"")

    # Update values that are provided.
    for i in 1:length(init_theta)
        x = init_theta[i]
        if x !== missing
            theta[i] = x
        end
    end

    # Update in `vi`.
    vi = setindex!!(vi, theta, spl)
    if linked
        vi = link!!(vi, spl, model)
    end

    return vi
end

"""
    initialstep(rng, model, sampler, varinfo; kwargs...)

Perform the initial sampling step of the `sampler` for the `model`.

The `varinfo` contains the initial samples, which can be provided by the user or
sampled randomly.
"""
function initialstep end
