export find_library, find_binary,
       find_driver, find_toolkit, find_toolchain


# names

const nvcc = "nvcc"

const libcuda = Compat.Sys.iswindows() ? "nvcuda" : "cuda"
const libnvml = Compat.Sys.iswindows() ? "nvml" : "nvidia-ml"


# generic stuff

# TODO: make this work like find_library: always search everywhere, but prefix locations priority.
# especially for find_binary.

# wrapper for Libdl.find_library, looking for more names in more locations.
find_library(name, prefix::String) = find_library(name, [prefix])
function find_library(name, prefixes=String[])
    @debug("Looking for $name library in $prefixes")

    # figure out names
    if Compat.Sys.iswindows()
        tag = Sys.WORD_SIZE == 64 ? "64" : "32"
        names = map(ver->"$name$(tag)_$(ver.major)$(ver.minor)", toolkits)
    else
        names = ["lib$name"]
    end

    # figure out locations
    locations = []
    for prefix in prefixes
        push!(locations, prefix)
        push!(locations, joinpath(prefix, "lib"))
        if Sys.WORD_SIZE == 64
            push!(locations, joinpath(prefix, "lib64"))
        end
    end

    @trace("Checking for $names in $locations")
    name = Libdl.find_library(names, locations)
    if isempty(name)
        error("Could not find $name library")
    end

    # find the full path of the library
    # NOTE: we could just as well use the result of `find_library,
    # but the user might have run this script with eg. LD_LIBRARY_PATH set
    # so we save the full path in order to always be able to load the correct library
    path = Libdl.dlpath(name)
    @debug("Using $name library at $path")
    return path
end

# similar to find_library, but for binaries.
# cfr. Libdl.find_library, looks for `name` in `prefix`, then PATH
find_binary(name, prefix::String) = find_binary(name, [prefix])
function find_binary(name, prefixes::Vector{String}=String[])
    @debug("Looking for $name binary in $prefixes")

    # figure out names
    if Compat.Sys.iswindows()
        name = "$name.exe"
    end

    # figure out locations
    locations = []
    for prefix in prefixes
        push!(locations, prefix)
        push!(locations, joinpath(prefix, "bin"))
    end
    let path = ENV["PATH"]
        dirs = split(path, Compat.Sys.iswindows() ? ';' : ':')
        filter!(path->!isempty(path), dirs)
        append!(locations, dirs)
    end

    @trace("Checking for $name in $locations")
    paths = [joinpath(location, name) for location in locations]
    paths = unique(filter(ispath, paths))
    if isempty(paths)
        error("Could not find $name binary")
    end

    path = first(paths)
    @debug("Using $name binary at $path")
    return path
end


# CUDA-specific

function find_driver()
    # figure out locations
    dirs = String[]
    ## look for the driver library (in the case LD_LIBRARY_PATH points to the installation)
    try
        libcuda_path = find_library(libcuda)
        dir = dirname(libcuda_path)
        if ismatch(r"^lib(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end
    ## look for the SMI binary (in the case PATH points to the installation)
    try
        nvidiasmi_path = find_binary("nvidia-smi")
        dir = dirname(nvidiasmi_path)
        if ismatch(r"^bin(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end

    # filter
    dirs = filter(isdir, unique(dirs))
    if length(dirs) > 1
        warn("Found multiple CUDA driver installations: ", join(dirs, ", ", " and "))
    elseif isempty(dirs)
        error("Could not find CUDA driver")
    end

    # select
    dir = first(dirs)
    @debug("Using CUDA driver at $dir")
    return dir
end

function find_toolkit()
    # figure out locations
    dirs = ["/usr/lib/nvidia-cuda-toolkit",
            "/usr/local/cuda",
            "/opt/cuda"]
    ## look for environment variables (taking priority over default values)
    envvars = ["CUDA_PATH", "CUDA_HOME", "CUDA_ROOT"]
    envvars_set = filter(var -> haskey(ENV, var), envvars)
    if length(envvars_set) > 0
        envvals = unique(map(var->ENV[var], envvars_set))
        if length(envvals) > 1
            warn("Multiple CUDA environment variables set to different values: $(join(envvars_set, ", ", " and "))")
        end
        unshift!(dirs, envvals...)
    end
    ## look for the runtime library (in the case LD_LIBRARY_PATH points to the installation)
    try
        libcudart_path = find_library("cudart")
        dir = dirname(libcudart_path)
        if ismatch(r"^lib(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end
    ## look for the compiler binary (in the case PATH points to the installation)
    try
        nvcc_path = find_binary(nvcc)
        dir = dirname(nvcc_path)
        if ismatch(r"^bin(32|64)?$", basename(dir))
            dir = dirname(dir)
        end
        push!(dirs, dir)
    catch ex
        isa(ex, ErrorException) || rethrow(ex)
    end

    dirs = filter(isdir, unique(dirs))
    if length(dirs) > 1
        warn("Found multiple CUDA toolkit installations: ", join(dirs, ", ", " and "))
    elseif isempty(dirs)
        error("Could not find CUDA toolkit; specify using CUDA_(dir|HOME|ROOT) environment variable")
    end

    # select
    dir = first(dirs)
    @debug("Using CUDA toolkit at $dir")
    return dir
end

type Toolchain
    version::VersionNumber
    nvcc::String
    flags::Vector{String}
end
function find_toolchain(toolkit_path)
    nvcc_path = find_binary(nvcc, toolkit_path)

    # parse the nvcc version
    re = r"release (?<major>\d+).(?<minor>\d+)"
    m = match(re, readstring(`$nvcc_path --version`))
    m != nothing || error("Could not get version from nvcc")
    version = VersionNumber(parse(Int, m[:major]), parse(Int, m[:minor]))
    @debug("Looking for toolchain supported by CUDA $version")

    # find a suitable host compiler
    flags = [ "--compiler-bindir" ]
    if !(is_windows() || is_apple())
        # Unix-like platforms: find compatible GCC binary

        # find the maximally supported version of gcc
        gcc_range = gcc_for_cuda(version)
        @trace("CUDA $version supports GCC $gcc_range")

        # enumerate possible names for the gcc binary
        # NOTE: this is coarse, and might list invalid, non-existing versions
        gcc_names = [ "gcc" ]
        for major in 3:7
            push!(gcc_names, "gcc-$major")
            for minor in 0:9
                push!(gcc_names, "gcc-$major.$minor")
                push!(gcc_names, "gcc$major$minor")
            end
        end

        # find the binary
        gcc_possibilities = []
        for gcc_name in gcc_names
            # check if the binary exists
            gcc_path = try
                find_binary(gcc_name)
            catch ex
                isa(ex, ErrorException) || rethrow(ex)
                continue
            end

            # parse the GCC version string
            verstring = chomp(readlines(`$gcc_path --version`)[1])
            m = match(Regex("^$gcc_name \\(.*\\) ([0-9.]+)"), verstring)
            if m === nothing
                warn("Could not parse GCC version info (\"$verstring\"), skipping this compiler.")
                continue
            end
            gcc_ver = VersionNumber(m.captures[1])
            @trace("Found GCC $gcc_ver at $gcc_path")

            if in(gcc_ver, gcc_range)
                push!(gcc_possibilities, (gcc_path, gcc_ver))
            end
        end

        if length(gcc_possibilities) == 0
            error("Could not find a suitable host compiler (your CUDA v$version needs GCC <= $(get(gcc_maxver))).")
        end
        sort!(gcc_possibilities; rev=true, lt=(a, b) -> a[2]<b[2])
        gcc_path, gcc_ver = gcc_possibilities[1]
        @debug("Using GCC $gcc_ver at $gcc_path")
        push!(flags, gcc_path)
    elseif is_windows()
        # Windows: just use cl.exe

        vc_versions = ["VS140COMNTOOLS", "VS120COMNTOOLS", "VS110COMNTOOLS", "VS100COMNTOOLS"]
        !any(x -> haskey(ENV, x), vc_versions) && error("Compatible Visual Studio installation cannot be found; Visual Studio 2015, 2013, 2012, or 2010 is required.")
        vs_cmd_tools_dir = ENV[vc_versions[first(find(x -> haskey(ENV, x), vc_versions))]]
        cl_path = joinpath(dirname(dirname(dirname(vs_cmd_tools_dir))), "VC", "bin", Sys.WORD_SIZE == 64 ? "amd64" : "", "cl.exe")

        @debug("Using Visual Studio compiler at $cl_path")
        push!(flags, cl_path)
    elseif is_apple()
        # GCC is no longer supported on MacOS so let's just use clang
        # TODO: proper version matching, etc

        clang_path = find_binary("clang")

        @trace("Using Clang at $clang_path")
        push!(flags, clang_path)
    end

    return Toolchain(version, nvcc_path, flags)
end
