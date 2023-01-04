function install(m::Module; kw...)
    options = Configs.read_options(m; kw...)
    return install(m, options)
end

function install(m::Module, options::Configs.Comonicon)
    # prepare env (only scratch space is mutable)
    install_project_env(m, options)
    # prepare .julia/bin/<command>
    install_entryfile(m, options)
    # download or build sysimg if configured
    # at .julia/scratchspaces/<uuid>/sysimg/lib<name>.dylib
    install_sysimg(m, options)

    haskey(ENV, "SHELL") || return
    shell = basename(ENV["SHELL"])
    # generate auto completion script
    # at .julia/completions
    install_completion(m, options, shell)
    return
end

function install_project_env(m::Module, options::Configs.Comonicon)
    scratch_env_dir = get_scratch!(m, "env")
    # rm old environment
    ispath(scratch_env_dir) && rm(scratch_env_dir; force = true, recursive = true)
    create_command_env(m, get_scratch!(m, "env"); test_deps = false)
    return
end

function install_entryfile(m::Module, options::Configs.Comonicon)
    bin = install_path(options, "bin")
    # generate entry file at .juila/bin
    entryfile = joinpath(bin, options.name)
    open(entryfile, "w+") do io
        print(io, entryfile_script(m, options))
    end
    chmod(entryfile, 0o777)
    return
end

function install_path(options::Configs.Comonicon, paths::String...)
    ensure_path(expanduser(joinpath(options.install.path, paths...)))
end

function install_sysimg(m::Module, options::Configs.Comonicon)
    isnothing(options.sysimg) && return
    sysimg = sysimg_dylib(m, options)

    # try download if download info is specified
    if !isnothing(options.download) && !isfile(sysimg)
        try
            download_sysimg(m, options)
            return
        catch
            @info "fail to download system image, build system image locally"
        end
    end

    build_sysimg(m, options; incremental = true, filter_stdlibs = false, cpu_target = "native")
    return
end

function install_completion(m::Module, options::Configs.Comonicon, shell::String)
    options.install.completion || return
    completions_dir = install_path(options, "completions")
    shell in ["zsh", "bash"] || return
    if shell == "zsh"
        completion_file = joinpath(completions_dir, "_" * options.name)
    elseif shell == "bash"
        completion_file = joinpath(completions_dir, options.name * "-" * "completion.bash")
    end
    open(completion_file, "w+") do io
        print(io, completion_script(m, options, shell))
    end
    return
end

function completion_script(m::Module, options::Configs.Comonicon, shell::String)
    isdefined(m, :CASTED_COMMANDS) || error("cannot find Comonicon CLI entry")
    haskey(m.CASTED_COMMANDS, "main") || error("cannot find Comonicon CLI entry")
    main = m.CASTED_COMMANDS["main"]

    if shell == "zsh"
        return ZSHCompletions.emit(main)
    elseif shell == "bash"
        return BashCompletions.emit(main)
    else
        error(
            "$shell autocompletion is not supported, " *
            "please open an issue at $COMONICON_URL for feature request.",
        )
    end
end

function entryfile_script(m::Module, options::Configs.Comonicon)
    cmds = String[]

    julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())
    push!(cmds, julia_exe)
    if !isnothing(options.sysimg)
        dylib = sysimg_dylib(m, options)
        push!(cmds, "--sysimage=" * dylib)
    end

    if options.install.nthreads > 1 || options.install.nthreads == "auto"
        push!(cmds, string("--threads=", options.install.nthreads))
    end

    push!(cmds, "--startup-file=no")
    push!(cmds, "--color=yes")
    push!(cmds, string("--compile=", options.install.compile))
    push!(cmds, string("--optimize=", options.install.optimize))
    push!(cmds, "-- \"\${BASH_SOURCE[0]}\" \"\$@\"")

    return """
    #!/usr/bin/env bash
    #=
    JULIA_PROJECT=$(get_scratch!(m, "env")) \\
    exec $(join(cmds, " \\\n    "))
    =#

    # generated by Comonicon for the CLI Application $(options.name)
    using $m
    exit($(nameof(m)).command_main())
    """
end

function ensure_path(path::String)
    if !ispath(path)
        @info "creating $path"
        mkpath(path)
    end
    return path
end
