#!/usr/bin/env julia
using KM3NeT
using Plots
GR.inline("png")

if length(ARGS) < 1
    println("Usage: ./live_royfit.jl DETX")
    exit(1)
end


const calib = KM3NeT.read_calibration(ARGS[1])

function main()
    println("Starting live ROyFit")

    for message in CHClient(ip"127.0.0.1", 55530, ["IO_EVT"])
        event = KM3NeT.read_io(IOBuffer(message.data), KM3NeT.DAQEvent)

        track = reconstruct(event)

        if track == nothing
            println("Skipping")
            continue
        end

        println(track)

        if rand() > 0.94
            println("Plotting...")
            hits = calibrate(event.hits, calib)
            plot(hits, track, max_z=calib.max_z)
            savefig("ztplot.png")
        end
    end
end



function reconstruct(event)
    hits = calibrate(event.hits, calib)
    triggered_hits = filter(h->h.triggered, hits)
    n_dus = length(unique(h->h.du, triggered_hits))
    n_doms = length(unique(h->h.dom_id, triggered_hits))
    if n_doms < 4
        return nothing
    end
    brightest_du = KM3NeT.most_frequent(h -> h.du, triggered_hits)
    du_hits = filter(h->h.du == brightest_du, triggered_hits)
    fit = KM3NeT.single_du_fit(du_hits)
    # return KM3NeT.prefit(triggered_hits)
    return fit
end


main()
