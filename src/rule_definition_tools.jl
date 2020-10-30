# These are some macros (and supporting functions) to make it easier to define rules.
"""
    @scalar_rule(f(x₁, x₂, ...),
                 @setup(statement₁, statement₂, ...),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

A convenience macro that generates simple scalar forward or reverse rules using
the provided partial derivatives. Specifically, generates the corresponding
methods for `frule` and `rrule`:

    function ChainRulesCore.frule((NO_FIELDS, Δx₁, Δx₂, ...), ::typeof(f), x₁::Number, x₂::Number, ...)
        Ω = f(x₁, x₂, ...)
        \$(statement₁, statement₂, ...)
        return Ω, (
                (∂f₁_∂x₁ * Δx₁ + ∂f₁_∂x₂ * Δx₂ + ...),
                (∂f₂_∂x₁ * Δx₁ + ∂f₂_∂x₂ * Δx₂ + ...),
                ...
            )
    end

    function ChainRulesCore.rrule(::typeof(f), x₁::Number, x₂::Number, ...)
        Ω = f(x₁, x₂, ...)
        \$(statement₁, statement₂, ...)
        return Ω, ((ΔΩ₁, ΔΩ₂, ...)) -> (
                NO_FIELDS,
                ∂f₁_∂x₁ * ΔΩ₁ + ∂f₂_∂x₁ * ΔΩ₂ + ...),
                ∂f₁_∂x₂ * ΔΩ₁ + ∂f₂_∂x₂ * ΔΩ₂ + ...),
                ...
            )
    end

If no type constraints in `f(x₁, x₂, ...)` within the call to `@scalar_rule` are
provided, each parameter in the resulting `frule`/`rrule` definition is given a
type constraint of `Number`.
Constraints may also be explicitly be provided to override the `Number` constraint,
e.g. `f(x₁::Complex, x₂)`, which will constrain `x₁` to `Complex` and `x₂` to
`Number`.

At present this does not support defining for closures/functors.
Thus in reverse-mode, the first returned partial,
representing the derivative with respect to the function itself, is always `NO_FIELDS`.
And in forward-mode, the first input to the returned propagator is always ignored.

The result of `f(x₁, x₂, ...)` is automatically bound to `Ω`. This
allows the primal result to be conveniently referenced (as `Ω`) within the
derivative/setup expressions.

This macro assumes complex functions are holomorphic. In general, for non-holomorphic
functions, the `frule` and `rrule` must be defined manually.

The `@setup` argument can be elided if no setup code is need. In other
words:

    @scalar_rule(f(x₁, x₂, ...),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

is equivalent to:

    @scalar_rule(f(x₁, x₂, ...),
                 @setup(nothing),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

For examples, see ChainRules' `rulesets` directory.

See also: [`frule`](@ref), [`rrule`](@ref).
"""
macro scalar_rule(call, maybe_setup, partials...)
    call, setup_stmts, inputs, partials = _normalize_scalarrules_macro_input(
        call, maybe_setup, partials
    )
    f = call.args[1]

    frule_expr = scalar_frule_expr(f, call, setup_stmts, inputs, partials)
    rrule_expr = scalar_rrule_expr(f, call, setup_stmts, inputs, partials)

    ############################################################################
    # Final return: building the expression to insert in the place of this macro
    code = quote
        if !($f isa Type) && fieldcount(typeof($f)) > 0
            throw(ArgumentError(
                "@scalar_rule cannot be used on closures/functors (such as $($f))"
            ))
        end

        $(frule_expr)
        $(rrule_expr)
    end
end


"""
    _normalize_scalarrules_macro_input(call, maybe_setup, partials)

returns (in order) the correctly escaped:
    - `call` with out any type constraints
    - `setup_stmts`: the content of `@setup` or `nothing` if that is not provided,
    -  `inputs`: with all args having the constraints removed from call, or
        defaulting to `Number`
    - `partials`: which are all `Expr{:tuple,...}`
"""
function _normalize_scalarrules_macro_input(call, maybe_setup, partials)
    ############################################################################
    # Setup: normalizing input form etc

    if Meta.isexpr(maybe_setup, :macrocall) && maybe_setup.args[1] == Symbol("@setup")
        setup_stmts = map(esc, maybe_setup.args[3:end])
    else
        setup_stmts = (nothing,)
        partials = (maybe_setup, partials...)
    end
    @assert Meta.isexpr(call, :call)

    # Annotate all arguments in the signature as scalars
    inputs = esc.(_constrain_and_name.(call.args[2:end], :Number))
    # Remove annotations and escape names for the call
    call.args[2:end] .= _unconstrain.(call.args[2:end])
    call.args = esc.(call.args)

    # For consistency in code that follows we make all partials tuple expressions
    partials = map(partials) do partial
        if Meta.isexpr(partial, :tuple)
            partial
        else
            length(inputs) == 1 || error("Invalid use of `@scalar_rule`")
            Expr(:tuple, partial)
        end
    end

    return call, setup_stmts, inputs, partials
end


function scalar_frule_expr(f, call, setup_stmts, inputs, partials)
    n_outputs = length(partials)
    n_inputs = length(inputs)

    # Δs is the input to the propagator rule
    # because this is push-forward there is one per input to the function
    Δs = [esc(Symbol(:Δ, i)) for i in 1:n_inputs]
    pushforward_returns = map(1:n_outputs) do output_i
        ∂s = partials[output_i].args
        propagation_expr(Δs, ∂s)
    end
    if n_outputs > 1
        # For forward-mode we return a Composite if output actually a tuple.
        pushforward_returns = Expr(
            :call, :(ChainRulesCore.Composite{typeof($(esc(:Ω)))}), pushforward_returns...
        )
    else
        pushforward_returns = first(pushforward_returns)
    end

    return quote
        # _ is the input derivative w.r.t. function internals. since we do not
        # allow closures/functors with @scalar_rule, it is always ignored
        function ChainRulesCore.frule((_, $(Δs...)), ::typeof($f), $(inputs...))
            $(esc(:Ω)) = $call
            $(setup_stmts...)
            return $(esc(:Ω)), $pushforward_returns
        end
    end
end

function scalar_rrule_expr(f, call, setup_stmts, inputs, partials)
    n_outputs = length(partials)
    n_inputs = length(inputs)

    # Δs is the input to the propagator rule
    # because this is a pull-back there is one per output of function
    Δs = [Symbol(:Δ, i) for i in 1:n_outputs]

    # 1 partial derivative per input
    pullback_returns = map(1:n_inputs) do input_i
        ∂s = [partial.args[input_i] for partial in partials]
        propagation_expr(Δs, ∂s, true)
    end

    # Multi-output functions have pullbacks with a tuple input that will be destructured
    pullback_input = n_outputs == 1 ? first(Δs) : Expr(:tuple, Δs...)
    pullback = quote
        function $(esc(propagator_name(f, :pullback)))($pullback_input)
            return (NO_FIELDS, $(pullback_returns...))
        end
    end

    return quote
        function ChainRulesCore.rrule(::typeof($f), $(inputs...))
            $(esc(:Ω)) = $call
            $(setup_stmts...)
            return $(esc(:Ω)), $pullback
        end
    end
end

"""
    propagation_expr(Δs, ∂s, _conj = false)

    Returns the expression for the propagation of
    the input gradient `Δs` though the partials `∂s`.
    Specify `_conj = true` to conjugate the partials.
"""
function propagation_expr(Δs, ∂s, _conj = false)
    # This is basically Δs ⋅ ∂s
    ∂s = map(esc, ∂s)
    n∂s = length(∂s)

    # Due to bugs in Julia 1.0, we can't use `.+`  or `.*` inside expression literals.
    ∂_mul_Δs = if _conj
        ntuple(i->:(conj($(∂s[i])) * $(Δs[i])), n∂s)
    else
        ntuple(i->:($(∂s[i]) * $(Δs[i])), n∂s)
    end

    # Avoiding the extra `+` operation, it is potentially expensive for vector mode AD.
    sumed_∂_mul_Δs = if n∂s > 1
        # we use `@.` to broadcast `*` and `+`
        :(@. +($(∂_mul_Δs...)))
    else
        # Note: we don't want to do broadcasting with only 1 multiply (no `+`),
        # because some arrays overload multiply with scalar. Avoiding
        # broadcasting saves compilation time.
        ∂_mul_Δs[1]
    end

    return :(@muladd $sumed_∂_mul_Δs)
end

"""
    propagator_name(f, propname)

Determines a reasonable name for the propagator function.
The name doesn't really matter too much as it is a local function to be returned
by `frule` or `rrule`, but a good name make debugging easier.
`f` should be some form of AST representation of the actual function,
`propname` should be either `:pullback` or `:pushforward`

This is able to deal with fairly complex expressions for `f`:

    julia> propagator_name(:bar, :pushforward)
    :bar_pushforward

    julia> propagator_name(esc(:(Base.Random.foo)), :pullback)
    :foo_pullback
"""
propagator_name(f::Expr, propname::Symbol) = propagator_name(f.args[end], propname)
propagator_name(fname::Symbol, propname::Symbol) = Symbol(fname, :_, propname)
propagator_name(fname::QuoteNode, propname::Symbol) = propagator_name(fname.value, propname)

"""
    @non_differentiable(signature_expression)

A helper to make it easier to declare that a method is not not differentiable.
This is a short-hand for defining an [`frule`](@ref) and [`rrule`](@ref) that
return [`DoesNotExist()`](@ref) for all partials (except for the function `s̄elf`-partial
itself which is `NO_FIELDS`)

Keyword arguments should not be included.

```jldoctest
julia> @non_differentiable Base.:(==)(a, b)

julia> _, pullback = rrule(==, 2.0, 3.0);

julia> pullback(1.0)
(Zero(), DoesNotExist(), DoesNotExist())
```

You can place type-constraints in the signature:
```jldoctest
julia> @non_differentiable Base.length(xs::Union{Number, Array})

julia> frule((Zero(), 1), length, [2.0, 3.0])
(2, DoesNotExist())
```

!!! warning
    This helper macro covers only the simple common cases.
    It does not support Varargs, or `where`-clauses.
    For these you can declare the `rrule` and `frule` directly

"""
macro non_differentiable(sig_expr)
    Meta.isexpr(sig_expr, :call) || error("Invalid use of `@non_differentiable`")
    for arg in sig_expr.args
        _isvararg(arg) && error("@non_differentiable does not support Varargs like: $arg")
    end

    primal_name, orig_args = Iterators.peel(sig_expr.args)

    constrained_args = _constrain_and_name.(orig_args, :Any)
    primal_sig_parts = [:(::Core.Typeof($primal_name)), constrained_args...]

    unconstrained_args = _unconstrain.(constrained_args)

    primal_invoke = :($(primal_name)($(unconstrained_args...); kwargs...))

    quote
        $(_nondiff_frule_expr(primal_sig_parts, primal_invoke))
        $(_nondiff_rrule_expr(primal_sig_parts, primal_invoke))
    end
end

function _nondiff_frule_expr(primal_sig_parts, primal_invoke)
    return esc(:(
        function ChainRulesCore.frule($(gensym(:_)), $(primal_sig_parts...); kwargs...)
            # Julia functions always only have 1 output, so return a single DoesNotExist()
            return ($primal_invoke, DoesNotExist())
        end
    ))
end

function _nondiff_rrule_expr(primal_sig_parts, primal_invoke)
    num_primal_inputs = length(primal_sig_parts) - 1
    primal_name = first(primal_invoke.args)
    pullback_expr = Expr(
        :function,
        Expr(:call, propagator_name(primal_name, :pullback), :_),
        Expr(:tuple, NO_FIELDS, ntuple(_->DoesNotExist(), num_primal_inputs)...)
    )
    return esc(:(
        function ChainRulesCore.rrule($(primal_sig_parts...); kwargs...)
            return ($primal_invoke, $pullback_expr)
        end
    ))
end


###########
# Helpers

"""
    _isvararg(expr)

returns true if the expression could represent a vararg

```jldoctest
julia> ChainRulesCore._isvararg(:(x...))
true

julia> ChainRulesCore._isvararg(:(x::Int...))
true

julia> ChainRulesCore._isvararg(:(::Int...))
true

julia> ChainRulesCore._isvararg(:(x::Vararg))
true

julia> ChainRulesCore._isvararg(:(x::Vararg{Int}))
true

julia> ChainRulesCore._isvararg(:(::Vararg))
true

julia> ChainRulesCore._isvararg(:(::Vararg{Int}))
true

julia> ChainRulesCore._isvararg(:(x))
false
````
"""
_isvararg(expr) = false
function _isvararg(expr::Expr)
    Meta.isexpr(expr, :...) && return true
    if Meta.isexpr(expr, :(::))
        constraint = last(expr.args)
        constraint == :Vararg && return true
        Meta.isexpr(constraint, :curly) && first(constraint.args) == :Vararg && return true
    end
    return false
end


"turn both `a` and `a::S` into `a`"
_unconstrain(arg::Symbol) = arg
function _unconstrain(arg::Expr)
    Meta.isexpr(arg, :(::), 2) && return arg.args[1]  # drop constraint.
    error("malformed arguments: $arg")
end

"turn both `a` and `::constraint` into `a::constraint` etc"
function _constrain_and_name(arg::Expr, _)
    Meta.isexpr(arg, :(::), 2) && return arg  # it is already fine.
    Meta.isexpr(arg, :(::), 1) && return Expr(:(::), gensym(), arg.args[1])  #add name
    error("malformed arguments: $arg")
end
_constrain_and_name(name::Symbol, constraint) = Expr(:(::), name, constraint)  # add type
