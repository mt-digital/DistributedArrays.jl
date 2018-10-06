###
# Distributed broadcast implementation
##

using Base.Broadcast
import Base.Broadcast: BroadcastStyle, Broadcasted, _max

# We define a custom ArrayStyle here since we need to keep track of
# the fact that it is Distributed and what kind of underlying broadcast behaviour
# we will encounter.
struct DArrayStyle{Style <: BroadcastStyle} <: Broadcast.AbstractArrayStyle{Any} end
DArrayStyle(::S) where {S} = DArrayStyle{S}()
DArrayStyle(::S, ::Val{N}) where {S,N} = DArrayStyle(S(Val(N)))
DArrayStyle(::Val{N}) where N = DArrayStyle{Broadcast.DefaultArrayStyle{N}}()

BroadcastStyle(::Type{<:DArray{<:Any, N, A}}) where {N, A} = DArrayStyle(BroadcastStyle(A), Val(N))

# promotion rules
function BroadcastStyle(::DArrayStyle{AStyle}, ::DArrayStyle{BStyle}) where {AStyle, BStyle}
    DArrayStyle{BroadcastStyle(AStyle, BStyle)}()
end

# # deal with one layer deep lazy arrays
# BroadcastStyle(::Type{<:LinearAlgebra.Transpose{<:Any,T}}) where T <: DArray = BroadcastStyle(T)
# BroadcastStyle(::Type{<:LinearAlgebra.Adjoint{<:Any,T}}) where T <: DArray = BroadcastStyle(T)
BroadcastStyle(::Type{<:SubArray{<:Any,<:Any,<:T}}) where T <: DArray = BroadcastStyle(T)

# # This Union is a hack. Ideally Base would have a Transpose <: WrappedArray <: AbstractArray
# # and we could define our methods in terms of Union{DArray, WrappedArray{<:Any, <:DArray}}
# const DDestArray = Union{DArray,
#                          LinearAlgebra.Transpose{<:Any,<:DArray},
#                          LinearAlgebra.Adjoint{<:Any,<:DArray},
#                          SubArray{<:Any, <:Any, <:DArray}}
const DDestArray = DArray

# This method is responsible for selection the output type of broadcast
function Base.similar(bc::Broadcasted{<:DArrayStyle{Style}}, ::Type{ElType}) where {Style, ElType}
    DArray(map(length, axes(bc))) do I 
        # create fake Broadcasted for underlying ArrayStyle
        bc′ = Broadcasted{Style}(identity, (), map(length, I))
        similar(bc′, ElType)
    end
end

##
# We purposefully only specialise `copyto!`,
# Broadcast implementation that defers to the underlying BroadcastStyle. We can't 
# assume that `getindex` is fast, furthermore  we can't assume that the distribution of
# DArray accross workers is equal or that the underlying array type is consistent.
#
# Implementation:
#   - first distribute all arguments
#     - Q: How do decide on the cuts
#   - then localise arguments on each node
##
@inline function Base.copyto!(dest::DDestArray, bc::Broadcasted)
    axes(dest) == axes(bc) || Broadcast.throwdm(axes(dest), axes(bc))

    # Distribute Broadcasted
    # This will turn local AbstractArrays into DArrays
    dbc = bcdistribute(bc)

    asyncmap(procs(dest)) do p
        remotecall_fetch(p) do
            # get the indices for the localpart
            lidcs = localindices(dest)
            # create a local version of the broadcast, by constructing views
            # Note: creates copies of the argument
            lbc = bclocal(dbc, lidcs)
            Base.copyto!(localpart(dest), lbc)
            return nothing
        end
    end
    return dest
end

function Broadcast.dotview(D::DArray, args...)
    if length(args) == 1  && length(args) != ndims(D) && args[1] isa UnitRange
        I = CartesianIndices(size(D))[args[1]]
        minI = minimum(I)
        maxI = maximum(I)

        cI = ntuple(i->minI[i]:maxI[i], ndims(D))
        return view(D, cI...)
    end
    return Base.maybeview(D, args...)
end

@inline function Base.copyto!(dest::SubDArray, bc::Broadcasted)
    axes(dest) == axes(bc) || Broadcast.throwdm(axes(dest), axes(bc))
    dbc = bcdistribute(bc)

    asyncmap(procs(dest)) do p
        remotecall_fetch(p) do
            lidcs = localindices(parent(dest))
            I = map(intersect, dest.indices, lidcs)
            any(isempty, I) && return nothing
            lbc = bclocal(dbc, I)

            lviewidcs = ntuple(i -> _localindex(I[i], first(lidcs[i]) - 1), ndims(dest))
            Base.copyto!(view(localpart(parent(dest)), lviewidcs...), lbc)
            return nothing
	end
    end
    return dest
end

@inline function Base.copy(bc::Broadcasted{<:DArrayStyle})
    dbc = bcdistribute(bc)
    # TODO: teach DArray about axes since this is wrong for OffsetArrays
    DArray(map(length, axes(bc))) do I
        lbc = bclocal(dbc, I)
        copy(lbc)
    end
end

# _bcview creates takes the shapes of a view and the shape of a broadcasted argument,
# and produces the view over that argument that constitutes part of the broadcast
# it is in a sense the inverse of _bcs in Base.Broadcast
_bcview(::Tuple{}, ::Tuple{}) = ()
_bcview(::Tuple{}, view::Tuple) = ()
_bcview(shape::Tuple, ::Tuple{}) = (shape[1], _bcview(tail(shape), ())...)
function _bcview(shape::Tuple, view::Tuple)
    return (_bcview1(shape[1], view[1]), _bcview(tail(shape), tail(view))...)
end

# _bcview1 handles the logic for a single dimension
function _bcview1(a, b)
    if a == 1 || a == 1:1
        return 1:1
    elseif first(a) <= first(b) <= last(a) &&
           first(a) <= last(b)  <= last(b)
        return b
    else
        throw(DimensionMismatch("broadcast view could not be constructed"))
    end
end

# Distribute broadcast
# TODO: How to decide on cuts
@inline bcdistribute(bc::Broadcasted{Style}) where Style = Broadcasted{DArrayStyle{Style}}(bc.f, bcdistribute_args(bc.args), bc.axes)
@inline bcdistribute(bc::Broadcasted{Style}) where Style<:DArrayStyle = Broadcasted{Style}(bc.f, bcdistribute_args(bc.args), bc.axes)

# ask BroadcastStyle to decide if argument is in need of being distributed
bcdistribute(x::T) where T = _bcdistribute(BroadcastStyle(T), x)
_bcdistribute(::DArrayStyle, x) = x
# Don't bother distributing singletons
_bcdistribute(::Broadcast.AbstractArrayStyle{0}, x) = x
_bcdistribute(::Broadcast.AbstractArrayStyle, x) = distribute(x)
_bcdistribute(::Any, x) = x

@inline bcdistribute_args(args::Tuple) = (bcdistribute(args[1]), bcdistribute_args(tail(args))...)
bcdistribute_args(args::Tuple{Any}) = (bcdistribute(args[1]),)
bcdistribute_args(args::Tuple{}) = ()

# dropping axes here since recomputing is easier
@inline bclocal(bc::Broadcasted{DArrayStyle{Style}}, idxs) where Style = Broadcasted{Style}(bc.f, bclocal_args(_bcview(axes(bc), idxs), bc.args))

# bclocal will do a view of the data and the copy it over
# except when the data already is local
function bclocal(x::SubOrDArray, idxs)
    bcidxs = _bcview(axes(x), idxs)
    makelocal(x, bcidxs...)
end
bclocal(x, idxs) = x

@inline bclocal_args(idxs, args::Tuple) = (bclocal(args[1], idxs), bclocal_args(idxs, tail(args))...)
bclocal_args(idxs, args::Tuple{Any}) = (bclocal(args[1], idxs),)
bclocal_args(idxs, args::Tuple{}) = ()
