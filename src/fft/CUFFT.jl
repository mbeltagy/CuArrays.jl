module CUFFT
# FFT interface for CuArrays

using ..CuArrays: libcufft, configured, CuArray
import AbstractFFTs: plan_fft, plan_fft!, plan_bfft, plan_bfft!,
    plan_rfft, plan_brfft, plan_inv, normalization, fft, bfft, ifft, rfft,
    Plan, ScaledPlan
import Base: show, *, convert, unsafe_convert, size, strides, ndims
import LinearAlgebra: mul!
import Base.Sys: WORD_SIZE

using LinearAlgebra

include("libcufft_types.jl")
include("error.jl")

const cufftNumber = Union{cufftDoubleReal,cufftReal,cufftDoubleComplex,cufftComplex}
# note trailing s to deconflict w/ header file
const cufftReals = Union{cufftDoubleReal,cufftReal}
const cufftComplexes = Union{cufftDoubleComplex,cufftComplex}
const cufftDouble = Union{cufftDoubleReal,cufftDoubleComplex}
const cufftSingle = Union{cufftReal,cufftComplex}
const cufftTypeDouble = Union{Type{cufftDoubleReal},Type{cufftDoubleComplex}}
const cufftTypeSingle = Union{Type{cufftReal},Type{cufftComplex}}

include("genericfft.jl")

# K is a flag for forward/backward
# also used as an alias for r2c/c2r

abstract type CuFFTPlan{T<:cufftNumber, K, inplace} <: Plan{T} end

mutable struct cCuFFTPlan{T<:cufftNumber,K,inplace,N} <: CuFFTPlan{T,K,inplace}
    plan::cufftHandle_t
    sz::NTuple{N,Int} # Julia size of input array
    osz::NTuple{N,Int} # Julia size of output array
    xtype::Int
    region::Any
    pinv::ScaledPlan # required by AbstractFFT API

    function cCuFFTPlan{T,K,inplace,N}(plan::cufftHandle_t, X::CuArray{T,N},
                                       sizey::Tuple, region, xtype::Integer
                                       ) where {T<:cufftNumber,K,inplace,N}
        # maybe enforce consistency of sizey
        p = new(plan, size(X), sizey, xtype, region)
        finalizer(destroy_plan, p)
        p
    end
end

cCuFFTPlan(plan,X,region,xtype::Integer) = cCuFFTPlan(plan,X,size(X),region,xtype)

mutable struct rCuFFTPlan{T<:cufftNumber,K,inplace,N} <: CuFFTPlan{T,K,inplace}
    plan::cufftHandle_t
    sz::NTuple{N,Int} # Julia size of input array
    osz::NTuple{N,Int} # Julia size of output array
    xtype::Int
    region::Any
    pinv::ScaledPlan # required by AbstractFFT API

    function rCuFFTPlan{T,K,inplace,N}(plan::cufftHandle_t, X::CuArray{T,N},
                                       sizey::Tuple, region, xtype::Integer
                                       ) where {T<:cufftNumber,K,inplace,N}
        # maybe enforce consistency of sizey
        p = new(plan, size(X), sizey, xtype, region)
        finalizer(destroy_plan, p)
        p
    end
end

rCuFFTPlan(plan,X,region,xtype::Integer) = rCuFFTPlan(plan,X,size(X),region,xtype)

const xtypenames = Dict{cufftType,String}(CUFFT_R2C => "real-to-complex",
                                          CUFFT_C2R => "complex-to-real",
                                          CUFFT_C2C => "complex",
                                          CUFFT_D2Z => "d.p. real-to-complex",
                                          CUFFT_Z2D => "d.p. complex-to-real",
                                          CUFFT_Z2Z => "d.p. complex")

function showfftdims(io, sz, T)
    if isempty(sz)
        print(io,"0-dimensional")
    elseif length(sz) == 1
        print(io, sz[1], "-element")
    else
        print(io, join(sz, "×"))
    end
    print(io, " CuArray of ", T)
end

function show(io::IO, p::CuFFTPlan{T,K,inplace}) where {T,K,inplace}
    print(io, inplace ? "CUFFT in-place " : "CUFFT ",
          xtypenames[p.xtype],
          K == CUFFT_FORWARD ? " forward" : " backward",
          " plan for ")
    showfftdims(io, p.sz, T)
end

# Note: we don't implement padded storage dimensions
function _mkplan(xtype, xdims, region)
    nrank = length(region)
    sz = [xdims[i] for i in region]
    csz = copy(sz)
    csz[1] = div(sz[1],2) + 1
    batch = prod(xdims) ÷ prod(sz)

    pp = Ref{cufftHandle_t}()
    if (nrank == 1) && (batch == 1)
        @check ccall((:cufftPlan1d,libcufft),cufftStatus_t,
                     (Ptr{cufftHandle_t}, Cint, cufftType, Cint),
                     pp, sz[1], xtype, 1)
    elseif (nrank == 2) && (batch == 1)
        @check ccall((:cufftPlan2d,libcufft),cufftStatus_t,
                     (Ptr{cufftHandle_t}, Cint, Cint, cufftType),
                     pp, sz[2], sz[1], xtype)
    elseif (nrank == 3) && (batch == 1)
        @check ccall((:cufftPlan3d,libcufft),cufftStatus_t,
                     (Ptr{cufftHandle_t}, Cint, Cint, Cint, cufftType),
                     pp, sz[3], sz[2], sz[1], xtype)

    else
        rsz = (length(sz) > 1) ? rsz = reverse(sz) : sz
        if ((region...,) == ((1:nrank)...,))
            # handle simple case ... simply! (for robustness)
            @check ccall((:cufftPlanMany,libcufft),cufftStatus_t,
                         (Ptr{cufftHandle_t}, Cint, Ptr{Cint}, # rank, dims
                          Ptr{Cint}, Cint, Cint, # nembed,stride,dist (input)
                          Ptr{Cint}, Cint, Cint, # nembed,stride,dist (output)
                          cufftType, Cint),
                         pp, nrank, Cint[rsz...], C_NULL, 1, 1, C_NULL, 1, 1,
                         xtype, batch)
        else
            if nrank==1 || all(diff(collect(region)) .== 1)
                # _stride: successive elements in innermost dimension
                # _dist: distance between first elements of batches
                if region[1] == 1
                    istride = 1
                    idist = prod(sz)
                    cdist = prod(csz)
                else
                    if region[end] != length(xdims)
                        throw(ArgumentError("batching dims must be sequential"))
                    end
                    istride = prod(xdims[1:region[1]-1])
                    idist = 1
                    cdist = 1
                end
                inembed = Cint[rsz...]
                cnembed = (length(csz) > 1) ? Cint[reverse(csz)...] : Cint[csz[1]]
                ostride = istride
                if xtype == CUFFT_R2C || xtype == CUFFT_D2Z
                    odist = cdist
                    onembed = cnembed
                else
                    odist = idist
                    onembed = inembed
                end
                if xtype == CUFFT_C2R || xtype == CUFFT_Z2D
                    idist = cdist
                    inembed = cnembed
                end
            else
                if any(diff(collect(region)) .< 1)
                    throw(ArgumentError("region must be an increasing sequence"))
                end
                cdims = collect(xdims)
                cdims[region[1]] = div(cdims[region[1]],2)+1

                if region[1] == 1
                    istride = 1
                    ii=1
                    while (ii < nrank) && (region[ii] == region[ii+1]-1)
                        ii += 1
                    end
                    idist = prod(xdims[1:ii])
                    cdist = prod(cdims[1:ii])
                    ngaps = 0
                else
                    istride = prod(xdims[1:region[1]-1])
                    idist = 1
                    cdist = 1
                    ngaps = 1
                end
                nem = ones(Int,nrank)
                cem = ones(Int,nrank)
                id = 1
                for ii=1:nrank-1
                    if region[ii+1] > region[ii]+1
                        ngaps += 1
                    end
                    while id < region[ii+1]
                        nem[ii] *= xdims[id]
                        cem[ii] *= cdims[id]
                        id += 1
                    end
                    @assert nem[ii] >= sz[ii]
                end
                if region[end] < length(xdims)
                    ngaps += 1
                end
                # CUFFT represents batches by a single stride (_dist)
                # so we must verify that region is consistent with this:
                if ngaps > 1
                    throw(ArgumentError("batch regions must be sequential"))
                end

                inembed = Cint[reverse(nem)...]
                cnembed = Cint[reverse(cem)...]
                ostride = istride
                if xtype == CUFFT_R2C || xtype == CUFFT_D2Z
                    odist = cdist
                    onembed = cnembed
                else
                    odist = idist
                    onembed = inembed
                end
                if xtype == CUFFT_C2R || xtype == CUFFT_Z2D
                    idist = cdist
                    inembed = cnembed
                end
            end
            @check ccall((:cufftPlanMany,libcufft),cufftStatus_t,
                         (Ptr{cufftHandle_t}, Cint, Ptr{Cint}, # rank, dims
                          Ptr{Cint}, Cint, Cint, # nembed,stride,dist (input)
                          Ptr{Cint}, Cint, Cint, # nembed,stride,dist (output)
                          cufftType, Cint),
                         pp, nrank, Cint[rsz...],
                         inembed, istride, idist, onembed, ostride, odist,
                         xtype, batch)
        end
    end
    pp[]
end

# this is used implicitly in the unsafe_execute methods below:
unsafe_convert(::Type{cufftHandle_t}, p::CuFFTPlan) = p.plan

convert(::Type{cufftHandle_t}, p::CuFFTPlan) = p.plan

destroy_plan(plan::CuFFTPlan) =
    ccall((:cufftDestroy,libcufft), Nothing, (cufftHandle_t,), plan.plan)

function assert_applicable(p::CuFFTPlan{T,K}, X::CuArray{T}) where {T,K}
    (size(X) == p.sz) ||
        throw(ArgumentError("CuFFT plan applied to wrong-size input"))
end

function assert_applicable(p::CuFFTPlan{T,K}, X::CuArray{T}, Y::CuArray{Ty}) where {T,K,Ty}
    assert_applicable(p, X)
    (size(Y) == p.osz) ||
        throw(ArgumentError("CuFFT plan applied to wrong-size output"))
    # type errors should be impossible by dispatch, but just in case:
    if p.xtype ∈ [CUFFT_C2R, CUFFT_Z2D]
        (Ty == real(T)) ||
            throw(ArgumentError("Type mismatch for argument Y"))
    elseif p.xtype ∈ [CUFFT_R2C, CUFFT_D2Z]
        (Ty == complex(T)) ||
            throw(ArgumentError("Type mismatch for argument Y"))
    else
        (Ty == T) ||
            throw(ArgumentError("Type mismatch for argument Y"))
    end
end

function unsafe_execute!(plan::cCuFFTPlan{cufftComplex,K,true,N},
                         x::CuArray{cufftComplex,N}) where {K,N}
    @assert plan.xtype == CUFFT_C2C
    @check ccall((:cufftExecC2C,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftComplex}, Ptr{cufftComplex},
                  Cint),
                 plan, x, x, K)
end
function unsafe_execute!(plan::rCuFFTPlan{cufftComplex,K,true,N},
                         x::CuArray{cufftComplex,N}) where {K,N}
    @assert plan.xtype == CUFFT_C2R
    @check ccall((:cufftExecC2R,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftComplex}, Ptr{cufftComplex}),
                 plan, x, x)
end

function unsafe_execute!(plan::cCuFFTPlan{cufftComplex,K,false,N},
                         x::CuArray{cufftComplex,N}, y::CuArray{cufftComplex}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_C2C
    @check ccall((:cufftExecC2C,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftComplex}, Ptr{cufftComplex}, Cint),
                 plan, x, y, K)
end
function unsafe_execute!(plan::rCuFFTPlan{cufftComplex,K,false,N},
                         x::CuArray{cufftComplex,N}, y::CuArray{cufftReal}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_C2R
    @check ccall((:cufftExecC2R,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftComplex}, Ptr{cufftReal}),
                 plan, x, y)
end

function unsafe_execute!(plan::rCuFFTPlan{cufftReal,K,false,N},
                         x::CuArray{cufftReal,N}, y::CuArray{cufftComplex,N}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_R2C
    @check ccall((:cufftExecR2C,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftReal}, Ptr{cufftComplex}),
                 plan, x, y)
end

# double prec.
function unsafe_execute!(plan::cCuFFTPlan{cufftDoubleComplex,K,true,N},
                         x::CuArray{cufftDoubleComplex,N}) where {K,N}
    @assert plan.xtype == CUFFT_Z2Z
    @check ccall((:cufftExecZ2Z,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftDoubleComplex}, Ptr{cufftDoubleComplex},
                  Cint),
                 plan, x, x, K)
end
function unsafe_execute!(plan::rCuFFTPlan{cufftDoubleComplex,K,true,N},
                         x::CuArray{cufftDoubleComplex,N}) where {K,N}
    @assert plan.xtype == CUFFT_Z2D
    @check ccall((:cufftExecZ2D,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftDoubleComplex}, Ptr{cufftDoubleComplex}),
                 plan, x, x)
end

function unsafe_execute!(plan::cCuFFTPlan{cufftDoubleComplex,K,false,N},
                         x::CuArray{cufftDoubleComplex,N}, y::CuArray{cufftDoubleComplex}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_Z2Z
    @check ccall((:cufftExecZ2Z,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftDoubleComplex}, Ptr{cufftDoubleComplex}, Cint),
                 plan, x, y, K)
end
function unsafe_execute!(plan::rCuFFTPlan{cufftDoubleComplex,K,false,N},
                         x::CuArray{cufftDoubleComplex,N}, y::CuArray{cufftDoubleReal}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_Z2D
    @check ccall((:cufftExecZ2D,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftDoubleComplex}, Ptr{cufftDoubleReal}),
                 plan, x, y)
end

function unsafe_execute!(plan::rCuFFTPlan{cufftDoubleReal,K,false,N},
                         x::CuArray{cufftDoubleReal,N}, y::CuArray{cufftDoubleComplex,N}
                         ) where {K,N}
    @assert plan.xtype == CUFFT_D2Z
    @check ccall((:cufftExecD2Z,libcufft), cufftStatus_t,
                 (cufftHandle_t, Ptr{cufftDoubleReal}, Ptr{cufftDoubleComplex}),
                 plan, x, y)
end

###############
# Public API  #
###############

# region is an iterable subset of dimensions
# spec. an integer, range, tuple, or array

# inplace complex
function plan_fft!(X::CuArray{T,N}, region) where {T<:cufftComplexes,N}
    K = CUFFT_FORWARD
    inplace = true
    xtype = (T == cufftComplex) ? CUFFT_C2C : CUFFT_Z2Z

    pp = _mkplan(xtype, size(X), region)

    cCuFFTPlan{T,K,inplace,N}(pp, X, size(X), region, xtype)
end

function plan_bfft!(X::CuArray{T,N}, region) where {T<:cufftComplexes,N}
    K = CUFFT_INVERSE
    inplace = true
    xtype =  (T == cufftComplex) ? CUFFT_C2C : CUFFT_Z2Z

    pp = _mkplan(xtype, size(X), region)

    cCuFFTPlan{T,K,inplace,N}(pp, X, size(X), region, xtype)
end

# out-of-place complex
function plan_fft(X::CuArray{T,N}, region) where {T<:cufftComplexes,N}
    K = CUFFT_FORWARD
    xtype =  (T == cufftComplex) ? CUFFT_C2C : CUFFT_Z2Z
    inplace = false

    pp = _mkplan(xtype, size(X), region)

    cCuFFTPlan{T,K,inplace,N}(pp, X, size(X), region, xtype)
end

function plan_bfft(X::CuArray{T,N}, region) where {T<:cufftComplexes,N}
    K = CUFFT_INVERSE
    inplace = false
    xtype =  (T == cufftComplex) ? CUFFT_C2C : CUFFT_Z2Z

    pp = _mkplan(xtype, size(X), region)

    cCuFFTPlan{T,K,inplace,N}(pp, X, size(X), region, xtype)
end

# out-of-place real-to-complex
function plan_rfft(X::CuArray{T,N}, region) where {T<:cufftReals,N}
    K = CUFFT_FORWARD
    inplace = false
    xtype =  (T == cufftReal) ? CUFFT_R2C : CUFFT_D2Z

    pp = _mkplan(xtype, size(X), region)

    ydims = collect(size(X))
    ydims[region[1]] = div(ydims[region[1]],2)+1

    rCuFFTPlan{T,K,inplace,N}(pp, X, (ydims...,), region, xtype)
end

function plan_brfft(X::CuArray{T,N}, d::Integer, region::Any) where {T<:cufftComplexes,N}
    K = CUFFT_INVERSE
    inplace = false
    xtype =  (T == cufftComplex) ? CUFFT_C2R : CUFFT_Z2D
    ydims = collect(size(X))
    ydims[region[1]] = d

    pp = _mkplan(xtype, (ydims...,), region)

    rCuFFTPlan{T,K,inplace,N}(pp, X, (ydims...,), region, xtype)
end

# FIXME: plan_inv methods allocate needlessly (to provide type parameters)
# Perhaps use FakeArray types to avoid this.

function plan_inv(p::cCuFFTPlan{T,CUFFT_FORWARD,inplace,N}) where {T,N,inplace}
    X = CuArray{T}(undef, p.sz)
    pp = _mkplan(p.xtype, p.sz, p.region)
    ScaledPlan(cCuFFTPlan{T,CUFFT_INVERSE,inplace,N}(pp, X, p.sz, p.region,
                                                     p.xtype),
               normalization(X, p.region))
end

function plan_inv(p::cCuFFTPlan{T,CUFFT_INVERSE,inplace,N}) where {T,N,inplace}
    X = CuArray{T}(undef, p.sz)
    pp = _mkplan(p.xtype, p.sz, p.region)
    ScaledPlan(cCuFFTPlan{T,CUFFT_FORWARD,inplace,N}(pp, X, p.sz, p.region,
                                                     p.xtype),
               normalization(X, p.region))
end

function plan_inv(p::rCuFFTPlan{T,CUFFT_INVERSE,inplace,N}
                  ) where {T<:cufftComplexes,N,inplace}
    X = CuArray{real(T)}(undef, p.osz)
    Y = CuArray{T}(undef, p.sz)
    xtype = p.xtype == CUFFT_C2R ? CUFFT_R2C : CUFFT_D2Z
    pp = _mkplan(xtype, p.osz, p.region)
    ScaledPlan(rCuFFTPlan{real(T),CUFFT_FORWARD,inplace,N}(pp, X, p.sz, p.region,
                                                     xtype),
               normalization(X, p.region))
end

function plan_inv(p::rCuFFTPlan{T,CUFFT_FORWARD,inplace,N}
                  ) where {T<:cufftReals,N,inplace}
    X = CuArray{complex(T)}(undef, p.osz)
    Y = CuArray{T}(undef, p.sz)
    xtype = p.xtype == CUFFT_R2C ? CUFFT_C2R : CUFFT_Z2D
    pp = _mkplan(xtype, p.sz, p.region)
    ScaledPlan(rCuFFTPlan{complex(T),CUFFT_INVERSE,inplace,N}(pp, X, p.sz,
                                                              p.region, xtype),
               normalization(Y, p.region))
end


# The rest of the standard API

size(p::CuFFTPlan) = p.sz

function mul!(y::CuArray{Ty}, p::CuFFTPlan{T,K,false}, x::CuArray{T}
                  ) where {Ty,T,K}
    assert_applicable(p,x,y)
    unsafe_execute!(p,x,y)
    return y
end

function *(p::cCuFFTPlan{T,K,true,N}, x::CuArray{T,N}) where {T,K,N}
    assert_applicable(p,x)
    unsafe_execute!(p,x)
    x
end

function *(p::rCuFFTPlan{T,CUFFT_FORWARD,false,N}, x::CuArray{T,N}
           ) where {T<:cufftReals,N}
    @assert p.xtype ∈ [CUFFT_R2C,CUFFT_D2Z]
    y = CuArray{complex(T),N}(undef, p.osz)
    mul!(y,p,x)
    y
end

function *(p::rCuFFTPlan{T,CUFFT_INVERSE,false,N}, x::CuArray{T,N}
           ) where {T<:cufftComplexes,N}
    @assert p.xtype ∈ [CUFFT_C2R,CUFFT_Z2D]
    y = CuArray{real(T),N}(undef, p.osz)
    mul!(y,p,x)
    y
end

function *(p::cCuFFTPlan{T,K,false,N}, x::CuArray{T,N}) where {T,K,N}
    y = CuArray{T,N}(undef, p.osz)
    mul!(y,p,x)
    y
end

end # module
