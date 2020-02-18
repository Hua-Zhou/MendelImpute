"""
    phase(tgtfile, reffile, outfile; impute = true, width = 1200)

Phasing (haplotying) of `tgtfile` from a pool of haplotypes `reffile`
by sliding windows and saves result in `outfile`. By default, we will perform
imputation after phasing and window width is 700.


# Input
- `reffile`: VCF file with reference genotype (GT) data
- `tgtfile`: VCF file with target genotype (GT) data
- `impute` : true = imputes missing genotypes with phase information.
- `outfile`: the prefix for output filenames. Will not be generated if `impute` is false
- `width`  : number of SNPs (markers) in each sliding window. 
"""
function phase(
    tgtfile::AbstractString,
    reffile::AbstractString;
    impute::Bool = true,
    prephased::Bool=false,
    outfile::AbstractString = "imputed." * tgtfile,
    width::Int = 400,
    flankwidth::Int = round(Int, 0.1width)
    )
    # convert vcf files to numeric matrices (need a routine so it does this transposed)
    H = convert_ht(Float32, reffile)
    if prephased
        X = convert_ht(Float32, tgtfile, has_missing=true)
    else
        X = convert_gt(Float32, tgtfile)
    end

    # compute redundant haplotype sets. 
    X = copy(X')
    H = copy(H')
    hs = compute_optimal_halotype_set(X, H, width = width, prephased = prephased, flankwidth=flankwidth)

    # phasing (haplotyping)
    if prephased
        ph = phase_prephased(X, H, hapset=hs, width=width, flankwidth=flankwidth)
    else
        ph = phase(X, H, hapset = hs, width = width, verbose = false, flankwidth=flankwidth)
    end

    if impute
        # imputation without changing known entries
        # impute2!(X, H, ph)

        # create VCF reader and writer
        reader = VCF.Reader(openvcf(tgtfile, "r"))
        writer = VCF.Writer(openvcf(outfile, "w"), header(reader))

        # loop over each record
        for (i, record) in enumerate(reader)
            gtkey = VCF.findgenokey(record, "GT")
            if !isnothing(gtkey) 
                # loop over samples
                for (j, geno) in enumerate(record.genotype)
                    # if missing = '.' = 0x2e
                    if record.data[geno[gtkey][1]] == 0x2e
                        #find where snp is located in phase
                        hap1_position = searchsortedlast(ph[j].strand1.start, i)
                        hap2_position = searchsortedlast(ph[j].strand2.start, i)

                        #find the correct haplotypes 
                        hap1 = ph[j].strand1.haplotypelabel[hap1_position]
                        hap2 = ph[j].strand2.haplotypelabel[hap2_position]

                        # save actual allele to data. "0" (REF) => 0x30, "1" (ALT) => 0x31
                        a1, a2 = convert(Bool, H[i, hap1]), convert(Bool, H[i, hap2])
                        record.data[geno[gtkey][1]] = ifelse(a1, 0x31, 0x30)
                        record.data[geno[gtkey][2]] = 0x7c # phased data has separator '|'
                        record.data[geno[gtkey][3]] = ifelse(a2, 0x31, 0x30)
                    end
                end
            end
            write(writer, record)
        end

        # close 
        flush(writer); close(reader); close(writer)
    end

    return hs, ph
end

function phase_prephased(
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix{T};
    width::Int = 400,
    flankwidth::Int = round(Int, 0.1width),
    hapset::Union{Vector{OptimalHaplotypeSet}, Nothing} = nothing,
    fast_method::Bool = true
    ) where T <: Real

    # declare some constants
    snps = size(X, 1)
    people = Int(size(X, 2) / 2)
    haplotypes = size(H, 2)
    windows = floor(Int, snps / width)

    # compute redundant haplotype sets for each strand
    if isnothing(hapset)
        hapset = compute_optimal_halotype_set(X, H, width=width, verbose=verbose, prephased=true, Xtrue=Xtrue, flankwidth=flankwidth)
    end

    # allocate working arrays
    phase = [HaplotypeMosaicPair(snps) for i in 1:people]
    haplo_chain = ([copy(hapset[i].strand1[1]) for i in 1:people], [copy(hapset[1].strand2[1]) for i in 1:people])
    chain_next  = (BitVector(undef, haplotypes), BitVector(undef, haplotypes))
    window_span = (ones(Int, people), ones(Int, people))

    # begin intersecting haplotypes window by window
    @inbounds for i in 1:people, w in 2:windows

        # intersect all surviving haplotypes with next window in parallel:
        # A   B
        # |   |
        # C   D
        chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w]
        chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w]

        # strand 1 becomes empty
        if sum(chain_next[1]) == 0
            # delete all nonmatching haplotypes in previous windows
            for ww in (w - window_span[1][i]):(w - 1)
                hapset[i].strand1[ww] .= haplo_chain[1][i]
            end

            # reset counters and storage
            haplo_chain[1][i] .= hapset[i].strand1[w]
            window_span[1][i] = 1
        else
            haplo_chain[1][i] .= chain_next[1]
            window_span[1][i] += 1
        end

        # strand 2 becomes empty
        if sum(chain_next[2]) == 0
            # delete all nonmatching haplotypes in previous windows
            for ww in (w - window_span[2][i]):(w - 1)
                hapset[i].strand2[ww] .= haplo_chain[2][i]
            end

            # reset counters and storage
            haplo_chain[2][i] .= hapset[i].strand2[w]
            window_span[2][i] = 1
        else
            haplo_chain[2][i] .= chain_next[2]
            window_span[2][i] += 1
        end
    end

    # handle last few windows separately, since intersection may not become empty
    for i in 1:people
        for ww in (windows - window_span[1][i] + 1):windows
            hapset[i].strand1[ww] .= haplo_chain[1][i]
        end

        for ww in (windows - window_span[2][i] + 1):windows
            hapset[i].strand2[ww] .= haplo_chain[2][i]
        end
    end

    # phase window 1
    for i in 1:people
        hap1 = findfirst(hapset[i].strand1[1]) :: Int64
        hap2 = findfirst(hapset[i].strand2[1]) :: Int64
        push!(phase[i].strand1.start, 1)
        push!(phase[i].strand1.haplotypelabel, hap1)
        push!(phase[i].strand2.start, 1)
        push!(phase[i].strand2.haplotypelabel, hap2)
    end

    # find optimal break points and record info to phase. 
    strand1_intersect = chain_next[1]
    strand2_intersect = chain_next[2]
    @inbounds for w in 2:windows
        Hi = view(H, ((w - 2) * width + 1):(w * width), :)
        for i in 1:people
            strand1_intersect .= hapset[i].strand1[w - 1] .& hapset[i].strand1[w]
            strand2_intersect .= hapset[i].strand2[w - 1] .& hapset[i].strand2[w]
            if sum(strand1_intersect) == 0 && sum(strand2_intersect) == 0 && !fast_method
                Xi = view(X, ((w - 2) * width + 1):(w * width), i)
                s1_prev = phase[i].strand1.haplotypelabel[end]
                s2_prev = phase[i].strand2.haplotypelabel[end]

                # search breakpoints when choosing first pair
                s1_next = findfirst(hapset[i].strand1[w]) :: Int64
                s2_next = findfirst(hapset[i].strand2[w]) :: Int64
                bkpt, err_optim = search_breakpoint(Xi, Hi, (s1_prev, s1_next), (s2_prev, s2_next))
                # record info into phase
                push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpt[1])
                push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpt[2])
                push!(phase[i].strand1.haplotypelabel, s1_next)
                push!(phase[i].strand2.haplotypelabel, s2_next)

                # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                # s1_win_next = findall(hapset[i].strand1[w])
                # s2_win_next = findall(hapset[i].strand2[w])
                # best_bktp = (0, 0)
                # best_err  = typemax(Int)
                # best_s1_next = 0
                # best_s2_next = 0
                # for s2_next in s2_win_next, s1_next in s1_win_next
                #     bkpt, err_optim = search_breakpoint(Xi, Hi, (s1_prev, s1_next), (s2_prev, s2_next))
                #     if err_optim < best_err
                #         best_bktp, best_err, best_s1_next, best_s2_next = bkpt, err_optim, s1_next, s2_next
                #     end
                # end
                # push!(phase[i].strand1.start, (w - 2) * width + 1 + best_bktp[1])
                # push!(phase[i].strand2.start, (w - 2) * width + 1 + best_bktp[2])
                # push!(phase[i].strand1.haplotypelabel, best_s1_next)
                # push!(phase[i].strand2.haplotypelabel, best_s2_next)
            else
                Xi = view(X, ((w - 2) * width + 1):(w * width), i)
                if sum(strand1_intersect) == 0
                    # search strand1 breakpoints
                    # s2 = findfirst(hapset[i].strand2[w]) :: Int64
                    # s1_prev = phase[i].strand1.haplotypelabel[end]
                    # s1_next = findfirst(hapset[i].strand1[w]) :: Int64
                    # bkpt, err_optim = search_breakpoint(Xi, Hi, s2, (s1_prev, s1_next))
                    # # record info into phase
                    # push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpt)
                    # push!(phase[i].strand1.haplotypelabel, s1_next)

                    # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                    s1_prev = phase[i].strand1.haplotypelabel[end]
                    s1_win_next = findall(hapset[i].strand1[w])
                    s2_win_next = findall(hapset[i].strand2[w])
                    best_bktp = 0
                    best_err  = typemax(Int)
                    best_s1_next = 0
                    for s1_next in s1_win_next, s2_next in s2_win_next
                        bkpt, err_optim = search_breakpoint(Xi, Hi, s2_next, (s1_prev, s1_next))
                        if err_optim < best_err
                            best_bktp, best_err, best_s1_next = bkpt, err_optim, s1_next
                        end
                    end
                    # record info into phase
                    push!(phase[i].strand1.start, (w - 2) * width + 1 + best_bktp)
                    push!(phase[i].strand1.haplotypelabel, best_s1_next)
                end

                if sum(strand2_intersect) == 0
                    # search strand2 breakpoints
                    # s1 = findfirst(hapset[i].strand1[w]) :: Int64
                    # s2_prev = phase[i].strand2.haplotypelabel[end]
                    # s2_next = findfirst(hapset[i].strand2[w]) :: Int64
                    # bkpt, err_optim = search_breakpoint(Xi, Hi, s1, (s2_prev, s2_next))
                    # # record info into phase
                    # push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpt)
                    # push!(phase[i].strand2.haplotypelabel, s2_next)

                    # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                    s2_prev = phase[i].strand2.haplotypelabel[end]
                    s2_win_next = findall(hapset[i].strand2[w])
                    s1_win_next = findall(hapset[i].strand1[w])
                    best_bktp = 0
                    best_err  = typemax(Int)
                    best_s2_next = 0
                    for s2_next in s2_win_next, s1_next in s1_win_next
                        bkpt, err_optim = search_breakpoint(Xi, Hi, s1_next, (s2_prev, s2_next))
                        if err_optim < best_err
                            best_bktp, best_err, best_s2_next = bkpt, err_optim, s2_next
                        end
                    end
                    # record info into phase
                    push!(phase[i].strand2.start, (w - 2) * width + 1 + best_bktp)
                    push!(phase[i].strand2.haplotypelabel, best_s2_next)
                end
            end
        end
    end

    return phase 
end

"""
    phase(X, H, width=400, verbose=true)

Phasing (haplotying) of genotype matrix `X` from a pool of haplotypes `H`
by sliding windows.

# Input
* `X`: `p x n` matrix with missing values. Each column is genotypes of an individual.
* `H`: `p x d` haplotype matrix. Each column is a haplotype.
* `width`: width of the sliding window.
* `verbose`: display algorithmic information.
"""
function phase(
    X::AbstractMatrix{Union{Missing, T}},
    H::AbstractMatrix{T};
    hapset::Union{Vector{OptimalHaplotypeSet}, Nothing} = nothing,
    width::Int    = 400,
    flankwidth::Int = round(Int, 0.1width),
    verbose::Bool = true,
    Xtrue::Union{AbstractMatrix, Nothing} = nothing, # for testing
    fast_method::Bool = false
    ) where T <: Real

    # declare some constants
    snps, people = size(X)
    haplotypes = size(H, 2)
    windows = floor(Int, snps / width)

    # compute redundant haplotype sets using least squares criteria
    if isnothing(hapset)
        hapset = compute_optimal_halotype_set(X, H, width=width, verbose=verbose, prephased=false, Xtrue=Xtrue)
    end

    # allocate working arrays
    phase = [HaplotypeMosaicPair(snps) for i in 1:people]
    haplo_chain = ([copy(hapset[i].strand1[1]) for i in 1:people], [copy(hapset[1].strand2[1]) for i in 1:people])
    chain_next  = (BitVector(undef, haplotypes), BitVector(undef, haplotypes))
    window_span = (ones(Int, people), ones(Int, people))

    # first pass to decide haplotype configurations (i.e. hapset switchings)
    # this increases error slightly but seems like it decreases computational time
    flips = [falses(windows) for i in 1:people]
    for i in 1:people
        set_flip!(hapset[i].strand1, hapset[i].strand2, flips[i])
    end

    # TODO: parallel computing
    # second pass to phase and merge breakpoints
    # begin intersecting haplotypes window by window
    @inbounds for i in 1:people, w in 2:windows

        # Decide whether to cross over based on the larger intersection
        # A   B      A   B
        # |   |  or    X
        # C   D      C   D
        chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w] # not crossing over
        chain_next[2] .= haplo_chain[1][i] .& hapset[i].strand2[w] # crossing over
        AC = sum(chain_next[1])
        AD = sum(chain_next[2])
        chain_next[1] .= haplo_chain[2][i] .& hapset[i].strand1[w] # crossing over
        chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w] # not crossing over
        BC = sum(chain_next[1])
        BD = sum(chain_next[2])
        if AC + BD < AD + BC
            hapset[i].strand1[w], hapset[i].strand2[w] = hapset[i].strand2[w], hapset[i].strand1[w]
        end

        # intersect all surviving haplotypes with next window
        chain_next[1] .= haplo_chain[1][i] .& hapset[i].strand1[w]
        chain_next[2] .= haplo_chain[2][i] .& hapset[i].strand2[w]

        # strand 1 becomes empty
        if sum(chain_next[1]) == 0
            # delete all nonmatching haplotypes in previous windows
            for ww in (w - window_span[1][i]):(w - 1)
                hapset[i].strand1[ww] .= haplo_chain[1][i]
            end

            # reset counters and storage
            haplo_chain[1][i] .= hapset[i].strand1[w]
            window_span[1][i] = 1
        else
            haplo_chain[1][i] .= chain_next[1]
            window_span[1][i] += 1
        end

        # strand 2 becomes empty
        if sum(chain_next[2]) == 0
            # delete all nonmatching haplotypes in previous windows
            for ww in (w - window_span[2][i]):(w - 1)
                hapset[i].strand2[ww] .= haplo_chain[2][i]
            end

            # reset counters and storage
            haplo_chain[2][i] .= hapset[i].strand2[w]
            window_span[2][i] = 1
        else
            haplo_chain[2][i] .= chain_next[2]
            window_span[2][i] += 1
        end
    end

    # handle last few windows separately, since intersection may not become empty
    for i in 1:people
        for ww in (windows - window_span[1][i] + 1):windows
            hapset[i].strand1[ww] .= haplo_chain[1][i]
        end

        for ww in (windows - window_span[2][i] + 1):windows
            hapset[i].strand2[ww] .= haplo_chain[2][i]
        end
    end

    # phase window 1
    for i in 1:people
        hap1 = findfirst(hapset[i].strand1[1]) :: Int64
        hap2 = findfirst(hapset[i].strand2[1]) :: Int64
        push!(phase[i].strand1.start, 1)
        push!(phase[i].strand1.haplotypelabel, hap1)
        push!(phase[i].strand2.start, 1)
        push!(phase[i].strand2.haplotypelabel, hap2)

        # search all possible haplotypes configurations between window 1 and 2 (super slow)
        # Xi = view(X, 1:(2width), i)
        # Hi = view(H, 1:(2width), :)
        # hap1_win_cur = findall(hapset[i].strand1[1])
        # hap2_win_cur = findall(hapset[i].strand2[1])
        # hap1_win_next = findall(hapset[i].strand1[2])
        # hap2_win_next = findall(hapset[i].strand2[2])
        # best_hap1 = 0
        # best_hap2 = 0
        # best_bktp = 0
        # best_err  = typemax(Int)
        # for hap1_next in hap1_win_next, hap2_next in hap2_win_next, hap1 in hap1_win_cur, hap2 in hap2_win_cur
        #     bkpt, err_optim = search_breakpoint(Xi, Hi, (hap1, hap1_next), (hap2, hap2_next))
        #     if err_optim < best_err
        #         best_bktp, best_err, best_hap1, best_hap2 = bkpt, err_optim, hap1, hap2
        #     end
        # end
        # push!(phase[i].strand1.start, 1)
        # push!(phase[i].strand1.haplotypelabel, best_hap1)
        # push!(phase[i].strand2.start, 1)
        # push!(phase[i].strand2.haplotypelabel, best_hap2)
    end

    # find optimal break points and record info to phase. 
    strand1_intersect = chain_next[1]
    strand2_intersect = chain_next[2]
    @inbounds for w in 2:windows
        Hi = view(H, ((w - 2) * width + 1):(w * width), :)
        for i in 1:people
            strand1_intersect .= hapset[i].strand1[w - 1] .& hapset[i].strand1[w]
            strand2_intersect .= hapset[i].strand2[w - 1] .& hapset[i].strand2[w]
            if sum(strand1_intersect) == 0 && sum(strand2_intersect) == 0 && !fast_method
                Xi = view(X, ((w - 2) * width + 1):(w * width), i)
                s1_prev = phase[i].strand1.haplotypelabel[end]
                s2_prev = phase[i].strand2.haplotypelabel[end]

                # search breakpoints when choosing first pair
                s1_next = findfirst(hapset[i].strand1[w]) :: Int64
                s2_next = findfirst(hapset[i].strand2[w]) :: Int64
                bkpt, err_optim = search_breakpoint(Xi, Hi, (s1_prev, s1_next), (s2_prev, s2_next))
                # record info into phase
                push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpt[1])
                push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpt[2])
                push!(phase[i].strand1.haplotypelabel, s1_next)
                push!(phase[i].strand2.haplotypelabel, s2_next)

                # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                # s1_win_next = findall(hapset[i].strand1[w])
                # s2_win_next = findall(hapset[i].strand2[w])
                # best_bktp = (0, 0)
                # best_err  = typemax(Int)
                # best_s1_next = 0
                # best_s2_next = 0
                # for s2_next in s2_win_next, s1_next in s1_win_next
                #     bkpt, err_optim = search_breakpoint(Xi, Hi, (s1_prev, s1_next), (s2_prev, s2_next))
                #     if err_optim < best_err
                #         best_bktp, best_err, best_s1_next, best_s2_next = bkpt, err_optim, s1_next, s2_next
                #     end
                # end
                # push!(phase[i].strand1.start, (w - 2) * width + 1 + best_bktp[1])
                # push!(phase[i].strand2.start, (w - 2) * width + 1 + best_bktp[2])
                # push!(phase[i].strand1.haplotypelabel, best_s1_next)
                # push!(phase[i].strand2.haplotypelabel, best_s2_next)
            else
                Xi = view(X, ((w - 2) * width + 1):(w * width), i)
                if sum(strand1_intersect) == 0
                    # search strand1 breakpoints
                    # s2 = findfirst(hapset[i].strand2[w]) :: Int64
                    # s1_prev = phase[i].strand1.haplotypelabel[end]
                    # s1_next = findfirst(hapset[i].strand1[w]) :: Int64
                    # bkpt, err_optim = search_breakpoint(Xi, Hi, s2, (s1_prev, s1_next))
                    # # record info into phase
                    # push!(phase[i].strand1.start, (w - 2) * width + 1 + bkpt)
                    # push!(phase[i].strand1.haplotypelabel, s1_next)

                    # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                    s1_prev = phase[i].strand1.haplotypelabel[end]
                    s1_win_next = findall(hapset[i].strand1[w])
                    s2_win_next = findall(hapset[i].strand2[w])
                    best_bktp = 0
                    best_err  = typemax(Int)
                    best_s1_next = 0
                    for s1_next in s1_win_next, s2_next in s2_win_next
                        bkpt, err_optim = search_breakpoint(Xi, Hi, s2_next, (s1_prev, s1_next))
                        if err_optim < best_err
                            best_bktp, best_err, best_s1_next = bkpt, err_optim, s1_next
                        end
                    end
                    # record info into phase
                    push!(phase[i].strand1.start, (w - 2) * width + 1 + best_bktp)
                    push!(phase[i].strand1.haplotypelabel, best_s1_next)
                end

                if sum(strand2_intersect) == 0
                    # search strand2 breakpoints
                    # s1 = findfirst(hapset[i].strand1[w]) :: Int64
                    # s2_prev = phase[i].strand2.haplotypelabel[end]
                    # s2_next = findfirst(hapset[i].strand2[w]) :: Int64
                    # bkpt, err_optim = search_breakpoint(Xi, Hi, s1, (s2_prev, s2_next))
                    # # record info into phase
                    # push!(phase[i].strand2.start, (w - 2) * width + 1 + bkpt)
                    # push!(phase[i].strand2.haplotypelabel, s2_next)

                    # search breakpoints among all possible haplotypes (this improves error slightly but quite slow)
                    s2_prev = phase[i].strand2.haplotypelabel[end]
                    s2_win_next = findall(hapset[i].strand2[w])
                    s1_win_next = findall(hapset[i].strand1[w])
                    best_bktp = 0
                    best_err  = typemax(Int)
                    best_s2_next = 0
                    for s2_next in s2_win_next, s1_next in s1_win_next
                        bkpt, err_optim = search_breakpoint(Xi, Hi, s1_next, (s2_prev, s2_next))
                        if err_optim < best_err
                            best_bktp, best_err, best_s2_next = bkpt, err_optim, s2_next
                        end
                    end
                    # record info into phase
                    push!(phase[i].strand2.start, (w - 2) * width + 1 + best_bktp)
                    push!(phase[i].strand2.haplotypelabel, best_s2_next)
                end
            end
        end
    end

    return phase 
end

"""
    impute!(X, H, phase)

Imputes `X` completely using segments of haplotypes `H` where segments are stored in `phase`. 
Non-missing entries in `X` can be different after imputation. 
"""
function impute!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair}
    )

    fill!(X, 0)
    # loop over individuals
    for i in 1:size(X, 2)
        for s in 1:(length(phase[i].strand1.start) - 1)
            idx = phase[i].strand1.start[s]:(phase[i].strand1.start[s + 1] - 1)
            X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[s]]
        end
        idx = phase[i].strand1.start[end]:phase[i].strand1.length
        X[idx, i] = H[idx, phase[i].strand1.haplotypelabel[end]]
        for s in 1:(length(phase[i].strand2.start) - 1)
            idx = phase[i].strand2.start[s]:(phase[i].strand2.start[s + 1] - 1)
            X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[s]]
        end
        idx = phase[i].strand2.start[end]:phase[i].strand2.length
        X[idx, i] += H[idx, phase[i].strand2.haplotypelabel[end]]
    end
end

"""
    impute2!(X, H, phase)

Imputes missing entries of `X` using corresponding haplotypes `H` via `phase` information. 
Non-missing entries in `X` will not change. 
"""
function impute2!(
    X::AbstractMatrix,
    H::AbstractMatrix,
    phase::Vector{HaplotypeMosaicPair}
    )

    p, n = size(X)

    @inbounds for person in 1:n, snp in 1:p
        if ismissing(X[snp, person])
            #find where snp is located in phase
            hap1_position = searchsortedlast(phase[person].strand1.start, snp)
            hap2_position = searchsortedlast(phase[person].strand2.start, snp)

            #find the correct haplotypes 
            hap1 = phase[person].strand1.haplotypelabel[hap1_position]
            hap2 = phase[person].strand2.haplotypelabel[hap2_position]

            # imputation step 
            X[snp, person] = H[snp, hap1] + H[snp, hap2]
        end
    end

    return nothing
end
