# Atomic Functions (B.12)

# TODO:
# - _system and _block versions (see CUDA programming guide)
# - atomic_cas!

@generated function llvm_atomic(::Val{binop}, ptr::DevicePtr{T,A}, val::T, ::Val{ordering}) where
                               {binop, T, A, ordering}
    T_val = convert(LLVMType, T)
    T_ptr = convert(LLVMType, DevicePtr{T,A})
    T_actual_ptr = LLVM.PointerType(T_val)

    llvm_f, _ = create_function(T_val, [T_ptr, T_val])

    Builder(JuliaContext()) do builder
        entry = BasicBlock(llvm_f, "entry", JuliaContext())
        position!(builder, entry)

        actual_ptr = inttoptr!(builder, parameters(llvm_f)[1], T_actual_ptr)

        rv = atomic_rmw!(builder, binop,
                         actual_ptr, parameters(llvm_f)[2],
                         ordering, #=single_threaded=# false)

        ret!(builder, rv)
    end

    call_function(llvm_f, T, Tuple{DevicePtr{T,A}, T}, :((ptr,val)))
end

const binops = Dict(
    :xchg  => LLVM.API.LLVMAtomicRMWBinOpXchg,
    :add   => LLVM.API.LLVMAtomicRMWBinOpAdd,
    :sub   => LLVM.API.LLVMAtomicRMWBinOpSub,
    :and   => LLVM.API.LLVMAtomicRMWBinOpAnd,
    :or    => LLVM.API.LLVMAtomicRMWBinOpOr,
    :xor   => LLVM.API.LLVMAtomicRMWBinOpXor,
    :max   => LLVM.API.LLVMAtomicRMWBinOpMax,
    :min   => LLVM.API.LLVMAtomicRMWBinOpMin,
    :umax  => LLVM.API.LLVMAtomicRMWBinOpUMax,
    :umin  => LLVM.API.LLVMAtomicRMWBinOpUMin
)

# all atomic operations have acquire and/or release semantics,
# depending on whether they load or store values (mimics Base)
const aquire = LLVM.API.LLVMAtomicOrderingAcquire
const aquire_release = LLVM.API.LLVMAtomicOrderingAcquireRelease

# common arithmetic operations on integers using LLVM instructions
#
# > 8.6.6. atomicrmw Instruction
# >
# > nand is not supported. The other keywords are supported for i32 and i64 types, with the
# > following restrictions.
# >
# > - The pointer must be either a global pointer, a shared pointer, or a generic pointer
# >   that points to either the global address space or the shared address space.
for T in (Int32, Int64, UInt32, UInt64)
    ops = [:xchg, :add, :sub, :and, :or, :xor, :max, :min]

    ASs = Union{AS.Generic, AS.Global, AS.Shared}

    for op in ops
        # LLVM distinguishes signedness in the operation, not the integer type.
        rmw =  if T <: Unsigned && (op == :max || op == :min)
            Symbol("u$op")
        else
            Symbol("$op")
        end

        fn = Symbol("atomic_$(op)!")
        @eval @inline $fn(ptr::DevicePtr{$T,<:$ASs}, val::$T) =
            llvm_atomic($(Val(binops[rmw])), ptr, val, Val(aquire_release))
    end
end

# floating-point operations using NVVM intrinsics
# TODO: LLVM supports _some_ atomic_rmw ops with floating-point types
#       does NVPTX support those? why use NVVM intrinsics?
for A in (AS.Generic, AS.Global, AS.Shared)
    # declare float @llvm.nvvm.atomic.load.add.f32.p0f32(float* address, float val)
    # declare float @llvm.nvvm.atomic.load.add.f32.p1f32(float addrspace(1)* address, float val)
    # declare float @llvm.nvvm.atomic.load.add.f32.p3f32(float addrspace(3)* address, float val)
    # declare double @llvm.nvvm.atomic.load.add.f64.p0f64(double* address, double val)
    # declare double @llvm.nvvm.atomic.load.add.f64.p1f64(double addrspace(1)* address, double val)
    # declare double @llvm.nvvm.atomic.load.add.f64.p3f64(double addrspace(3)* address, double val)
    for T in (Float32, Float64)
        nb = sizeof(T)*8
        intr = "llvm.nvvm.atomic.load.add.f$nb.p$(convert(Int, A))f$nb"
        @eval @inline atomic_add!(ptr::DevicePtr{$T,$A}, val::$T) =
            ccall($intr, llvmcall, $T, (DevicePtr{$T,$A}, $T), ptr, val)
    end

    # declare i32 @llvm.nvvm.atomic.load.inc.32.p0i32(i32* address, i32 val)
    # declare i32 @llvm.nvvm.atomic.load.inc.32.p1i32(i32 addrspace(1)* address, i32 val)
    # declare i32 @llvm.nvvm.atomic.load.inc.32.p3i32(i32 addrspace(3)* address, i32 val)
    #
    # declare i32 @llvm.nvvm.atomic.load.dec.32.p0i32(i32* address, i32 val)
    # declare i32 @llvm.nvvm.atomic.load.dec.32.p1i32(i32 addrspace(1)* address, i32 val)
    # declare i32 @llvm.nvvm.atomic.load.dec.32.p3i32(i32 addrspace(3)* address, i32 val)
    for T in (Int32,), op in (:inc, :dec)
        nb = sizeof(T)*8
        intr = "llvm.nvvm.atomic.load.$op.$nb.p$(convert(Int, A))i$nb"

        fn = Symbol("atomic_$(op)!")
        @eval @inline $fn(ptr::DevicePtr{$T,$A}, val::$T) =
            ccall($intr, llvmcall, $T, (DevicePtr{$T,$A}, $T), ptr, val)
    end
end
