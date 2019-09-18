# This code is derived from the Julia SubArray implementation (MIT license)

# L is true if the view itself supports fast linear indexing
"""
    SSubArray

Statically sized SubArray.
"""
struct SSubArray{S,T,N,P,I,L} <: StaticArray{S, T, N}
    parent::P
    indices::I
    offset1::Int       # for linear indexing and pointer, only valid when L==true
    stride1::Int       # used only for linear indexing
    function SSubArray{S,T,N,P,I,L}(parent, indices, offset1, stride1) where {S,T,N,P,I,L}
        Base.@_inline_meta
        Base.check_parent_index_match(parent, indices)
        new(parent, indices, offset1, stride1)
    end
end
# Compute the linear indexability of the indices, and combine it with the linear indexing of the parent
function SSubArray(parent::Union{StaticArray{S}, HybridArray{S}}, indices::Tuple) where S
    Base.@_inline_meta
    SSubArray(IndexStyle(Base.viewindexing(indices), IndexStyle(parent)), all_dynamic_fixed_val(S, indices...), parent, Base.ensure_indexable(indices), Base.index_dimsum(indices...))
end
function SSubArray(::IndexCartesian, ::Val{:dynamic_fixed_true}, parent::Union{StaticArray{S}, HybridArray{S}}, indices::I, ::NTuple{N,Any}) where {S,I,N}
    Base.@_inline_meta
    SSubArray{S, eltype(typeof(parent)), N, typeof(parent), I, false}(parent, indices, 0, 0)
end
function SSubArray(::IndexLinear, ::Val{:dynamic_fixed_true}, parent::Union{StaticArray{S}, HybridArray{S}}, indices::I, ::NTuple{N,Any}) where {S,I,N}
    Base.@_inline_meta
    # Compute the stride and offset
    stride1 = Base.compute_stride1(parent, indices)
    SSubArray{S, eltype(typeof(parent)), N, typeof(parent), I, true}(parent, indices, Base.compute_offset1(parent, stride1, indices), stride1)
end
function SSubArray(indexing::Any, ::Val{:dynamic_fixed_false}, parent::Union{StaticArray{S}, HybridArray{S}}, indices::I, ::NTuple{N,Any}) where {S,I,N}
    return SubArray(indexing, parent, indices)
end

# This makes it possible to elide view allocation in cases where the
# view is indexed with a boundscheck but otherwise all its uses
# are inlined
@inline Base.throw_boundserror(A::SSubArray, I) =
    Base.__subarray_throw_boundserror(typeof(A), A.parent, A.indices, A.offset1, A.stride1, I)

# Simple utilities
size(V::SSubArray) = (Base.@_inline_meta; map(n->Int(Base.unsafe_length(n)), axes(V)))

similar(V::SSubArray, T::Type, dims::Dims) = similar(V.parent, T, dims)

sizeof(V::SSubArray) = length(V) * sizeof(eltype(V))

copy(V::SSubArray) = V.parent[V.indices...]

parent(V::SSubArray) = V.parent
parentindices(V::SSubArray) = V.indices

## Aliasing detection
dataids(A::SSubArray) = (dataids(A.parent)..., Base._splatmap(dataids, A.indices)...)
unaliascopy(A::SSubArray) = typeof(A)(unaliascopy(A.parent), map(unaliascopy, A.indices), A.offset1, A.stride1)

# When the parent is an Array we can trim the size down a bit. In the future this
# could possibly be extended to any mutable array.
function unaliascopy(V::SSubArray{S,T,N,A,I,LD}) where {S,T,N,A<:Array,I<:Tuple{Vararg{Union{Real,AbstractRange,Array}}},LD}
    dest = Array{T}(undef, index_lengths(V.indices...))
    copyto!(dest, V)
    SSubArray{S,T,N,A,I,LD}(dest, map(_trimmedindex, V.indices), 0, Int(LD))
end

function Base.unsafe_view(A::Union{StaticArray, HybridArray}, I::Vararg{Base.ViewIndex,<:Any})
    Base.@_inline_meta
    SSubArray(A, I)
end

Base.unsafe_view(V::SSubArray, I::Vararg{Base.ViewIndex,N}) where {N} =
    (Base.@_inline_meta; Base._maybe_reindex(V, I))
Base._maybe_reindex(V::SSubArray, I) = (Base.@_inline_meta; Base._maybe_reindex(V, I, I))
Base._maybe_reindex(V::SSubArray, I, ::Tuple{AbstractArray{<:Base.AbstractCartesianIndex}, Vararg{Any}}) =
    (Base.@_inline_meta; SSubArray(V, I))
# But allow arrays of CartesianIndex{1}; they behave just like arrays of Ints
Base._maybe_reindex(V::SSubArray, I, A::Tuple{AbstractArray{<:Base.AbstractCartesianIndex{1}}, Vararg{Any}}) =
    (Base.@_inline_meta; Base._maybe_reindex(V, I, Base.tail(A)))
Base._maybe_reindex(V::SSubArray, I, A::Tuple{Any, Vararg{Any}}) = (Base.@_inline_meta; Base._maybe_reindex(V, I, Base.tail(A)))
function Base._maybe_reindex(V::SSubArray, I, ::Tuple{})
    Base.@_inline_meta
    @inbounds idxs = to_indices(V.parent, Base.reindex(V.indices, I))
    SSubArray(V.parent, idxs)
end

# In general, we simply re-index the parent indices by the provided ones
SlowSSubArray{S,T,N,P,I} = SSubArray{S,T,N,P,I,false}
function getindex(V::SSubArray{S,T,N}, I::Vararg{Int,N}) where {S,T,N}
    Base.@_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds r = V.parent[Base.reindex(V.indices, I)...]
    r
end

# But SSubArrays with fast linear indexing pre-compute a stride and offset
FastSSubArray{S,T,N,P,I} = SSubArray{S,T,N,P,I,true}
function getindex(V::FastSSubArray, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + V.stride1*i]
    r
end
# We can avoid a multiplication if the first parent index is a Colon or AbstractUnitRange,
# or if all the indices are scalars, i.e. the view is for a single value only
FastContiguousSSubArray{S,T,N,P,I<:Union{Tuple{Union{Base.Slice, AbstractUnitRange}, Vararg{Any}},
                                      Tuple{Vararg{Base.ScalarIndex}}}} = SSubArray{S,T,N,P,I,true}
function getindex(V::FastContiguousSSubArray, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + i]
    r
end
# For vector views with linear indexing, we disambiguate to favor the stride/offset
# computation as that'll generally be faster than (or just as fast as) re-indexing into a range.
function getindex(V::FastSSubArray{<:Any, 1}, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + V.stride1*i]
    r
end
function getindex(V::FastContiguousSSubArray{<:Any, 1}, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds r = V.parent[V.offset1 + i]
    r
end

# Indexed assignment follows the same pattern as `getindex` above
function setindex!(V::SSubArray{T,N}, x, I::Vararg{Int,N}) where {T,N}
    Base.@_inline_meta
    @boundscheck checkbounds(V, I...)
    @inbounds V.parent[Base.reindex(V.indices, I)...] = x
    V
end
function setindex!(V::FastSSubArray, x, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + V.stride1*i] = x
    V
end
function setindex!(V::FastContiguousSSubArray, x, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + i] = x
    V
end
function setindex!(V::FastSSubArray{<:Any, 1}, x, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + V.stride1*i] = x
    V
end
function setindex!(V::FastContiguousSSubArray{<:Any, 1}, x, i::Int)
    Base.@_inline_meta
    @boundscheck checkbounds(V, i)
    @inbounds V.parent[V.offset1 + i] = x
    V
end

Base.IndexStyle(::Type{<:FastSSubArray}) = IndexLinear()
Base.IndexStyle(::Type{<:SSubArray}) = IndexCartesian()

# Strides are the distance in memory between adjacent elements in a given dimension
# which we determine from the strides of the parent
Base.strides(V::SSubArray) = substrides(strides(V.parent), V.indices)

Base.stride(V::SSubArray, d::Integer) = d <= ndims(V) ? strides(V)[d] : strides(V)[end] * size(V)[end]

Base.elsize(::Type{<:SSubArray{<:Any,<:Any,<:Any,P}}) where {P} = elsize(P)

Base.iscontiguous(A::SSubArray) = Base.iscontiguous(typeof(A))
Base.iscontiguous(::Type{<:SSubArray}) = false
Base.iscontiguous(::Type{<:FastContiguousSSubArray}) = true

Base.first_index(V::FastSSubArray) = V.offset1 + V.stride1 # cached for fast linear SSubArrays
function Base.first_index(V::SSubArray)
    P, I = parent(V), V.indices
    s1 = Base.compute_stride1(P, I)
    s1 + Base.compute_offset1(P, s1, I)
end
Base.unsafe_convert(::Type{Ptr{T}}, V::SSubArray{T,N,P,<:Tuple{Vararg{Base.RangeIndex}}}) where {T,N,P} =
    unsafe_convert(Ptr{T}, V.parent) + (first_index(V)-1)*sizeof(T)

Base.pointer(V::FastSSubArray, i::Int) = pointer(V.parent, V.offset1 + V.stride1*i)
Base.pointer(V::FastContiguousSSubArray, i::Int) = pointer(V.parent, V.offset1 + i)
Base.pointer(V::SSubArray, i::Int) = Base._pointer(V, i)
Base._pointer(V::SSubArray{<:Any,1}, i::Int) = pointer(V, (i,))
Base._pointer(V::SSubArray, i::Int) = pointer(V, Base._ind2sub(axes(V), i))

function Base.pointer(V::SSubArray{T,N,<:Array,<:Tuple{Vararg{Base.RangeIndex}}}, is::Tuple{Vararg{Int}}) where {T,N}
    index = Base.first_index(V)
    strds = strides(V)
    for d = 1:length(is)
        index += (is[d]-1)*strds[d]
    end
    return pointer(V.parent, index)
end

axes(S::SSubArray) = (Base.@_inline_meta; Base._indices_sub(S.indices...))

## Compatibility
# deprecate?
function Base.parentdims(s::SSubArray)
    nd = ndims(s)
    dimindex = Vector{Int}(undef, nd)
    sp = strides(s.parent)
    sv = strides(s)
    j = 1
    for i = 1:ndims(s.parent)
        r = s.indices[i]
        if j <= nd && (isa(r,AbstractRange) ? sp[i]*step(r) : sp[i]) == sv[j]
            dimindex[j] = i
            j += 1
        end
    end
    dimindex
end


# move to StaticArrays maybe?
Base.strides(a::Union{SArray,MArray}) = Base.size_to_strides(1, size(a)...)
Base.strides(a::SizedArray) = strides(a.data)