__precompile__()

module KM3NeT

using StaticArrays
using HDF5

import Base: +, -, *

export
    Position, Direction,
    EventInfo, Track, Hit, CalibratedHit, RawHit, McHit, TimesliceHit,
    calibrate,
    read_indices, read_hits, read_tracks, read_calibration, read_event_info,
    svdfit, matrix, rows


# Basic types
struct Position <: FieldVector{3, Float64}
    x::Float64
    y::Float64
    z::Float64
end

# Base.*(x::Vector3D, y::Vector3D ) = Vector3D(SVector(y)* SVector(x))

struct Direction <: FieldVector{3, Float64}
    x::Float64
    y::Float64
    z::Float64
end

Base.show(io::IO, p::Position) = begin
    s = @sprintf "%.1f %.1f %.1f" p.x p.y p.z
    print(io, s)
end

Base.show(io::IO, d::Direction) = begin
    s = @sprintf "%.1f %.1f %.1f" d.x d.y d.z
    print(io, s)
end

struct EventInfo
    det_id::Int32
    frame_index::UInt32
    livetime_sec::UInt64
    mc_id::Int32
    mc_t::Float64
    n_events_gen::UInt64
    n_files_gen::UInt64
    overlays::UInt32
    trigger_counter::UInt64
    trigger_mask::UInt64
    utc_nanoseconds::UInt64
    utc_seconds::UInt64
    weight_w1::Float64
    weight_w2::Float64
    weight_w3::Float64
    run_id::UInt32
    event_id::UInt32
end

EventInfo(event_info::HDF5.HDF5Compound{17}) = EventInfo(event_info.data...)

# MC
struct Track
    bjorken_y::Float32
    dir::Direction
    pos::Position
    E::Float64
    interaction_channel::UInt8
    is_cc::Bool
    length::Float64
    t::Int32
    particle_type::Int32
end

Track(track::HDF5.HDF5Compound{15}) = begin
    d = track.data
    Track(d[1], Direction(d[2:4]...), Position(d[10:12]...),
          d[5], d[7], d[8], d[9], d[13], d[14])
end

Base.show(io::IO, t::Track) = begin
    E = @sprintf "%0.1f" t.E
    bjorken_y = @sprintf "%0.2f" t.bjorken_y
    print(io, "Track: bjorken_y($(bjorken_y)), t($(t.t)), " *
          "pos($(t.pos)), dir($(t.dir)), E($(E)), type($(t.particle_type))")
end


# Hardware
struct PMT
    channel_id::UInt8
    pos::Position
    dir::Direction
end


struct DOM
    id::UInt32
    floor::UInt8
    du::UInt8
    pmts::Vector{PMT}
end

struct Calibration
    det_id::Int32
    pos::Dict{Int32,Vector{KM3NeT.Position}}
    dir::Dict{Int32,Vector{KM3NeT.Direction}}
    t0::Dict{Int32,Vector{Integer}}
    du::Dict{Int32,UInt8}
    floor::Dict{Int32,UInt8}
end

Base.show(io::IO, c::Calibration) = begin
    print(io, "Calibration data for detector '$(c.det_id)' " *
              "with $(length(c.pos)) modules.")
end

# Signal
abstract type Hit end

struct RawHit <: Hit
    channel_id::UInt8
    dom_id::UInt32
    t::Int32
    tot::UInt8
    triggered::Bool
end

struct McHit <: Hit
    a::Float32
    origin::UInt32
    pmt_id::UInt32
    t::Int32
end

struct CalibratedHit <: Hit
    channel_id::UInt8
    dom_id::UInt32
    du::UInt8
    floor::UInt8
    t::Int32
    tot::UInt8
    triggered::Bool
    pos::Position
    dir::Direction
    t0::Int32
end

struct TimesliceHit <: Hit
    channel_id::Int8
    t::Int32
    tot::Int16
end

RawHit(hit::HDF5.HDF5Compound{5}) = begin
    RawHit(hit.data...)
end

Base.isless(lhs::Hit, rhs::Hit) = lhs.t < rhs.t



Base.show(io::IO, h::RawHit) = begin
    print(io, "$(typeof(h)): channel_id($(h.channel_id)), t($(h.t)), " *
          "tot($(h.tot)), dom_id($(h.dom_id)), triggered($(h.triggered))")
end


# I/O
function read_hits(fobj::HDF5.HDF5File, idx::Int, n_hits::Int)
    hits = Vector{RawHit}()
    channel_id = fobj["hits/channel_id"][idx+1:idx+n_hits]
    dom_id = fobj["hits/dom_id"][idx+1:idx+n_hits]
    t = fobj["hits/time"][idx+1:idx+n_hits]
    tot = fobj["hits/tot"][idx+1:idx+n_hits]
    triggered = fobj["hits/triggered"][idx+1:idx+n_hits]
    for i ∈ 1:n_hits
        hit =  RawHit(channel_id[i], dom_id[i], t[i], tot[i], triggered[i])
        push!(hits, hit)
    end
    return hits
end


function read_hits(filename::AbstractString, event_id::Int)
    f = h5open(filename, "r")
    hit_indices = read_indices(f, "/hits")
    idx = hit_indices[event_id+1][1]
    n_hits = hit_indices[event_id+1][2]
    hits = read_hits(f, idx, n_hits)::Vector{RawHit}
    close(f)
    return hits
end


function read_hits(filename::AbstractString,
                    event_ids::Union{Array{T}, UnitRange{T}}) where {T<:Integer}
    f = h5open(filename, "r")
    hit_indices = read_indices(f, "/hits")

    hits_collection = Dict{Int, Vector{RawHit}}()
    for event_id ∈ event_ids
        idx = hit_indices[event_id+1][1]
        n_hits = hit_indices[event_id+1][2]
        hits = read_hits(f, idx, n_hits)::Vector{RawHit}
        hits_collection[event_id] = hits
    end
    close(f)
    return hits_collection
end

function read_indices(filename::AbstractString, from::AbstractString)
    f = h5open(filename, "r")
    indices = read_indices(f, from)
    close(f)
    return indices
end

function read_indices(fobj::HDF5.HDF5File, from::AbstractString)
    idc = read(fobj, from * "/_indices")
    indices = [i.data for i ∈ idc]::Vector{Tuple{Int64,Int64}}
    return indices
end


function read_tracks(fobj::HDF5.HDF5File)
    tracks = Dict{Int, Vector{Track}}()
    data = read(fobj, "mc_tracks")
    for d in data
        event_id = d.data[15]
        if !haskey(tracks, event_id)
            tracks[event_id] = Vector{Track}()
        end
        push!(tracks[event_id], Track(d))
    end
    return tracks
end


function read_tracks(filename::AbstractString)
    f = h5open(filename, "r")
    tracks = read_tracks(f)
    close(f)
    tracks
end


function read_calibration(filename::AbstractString)
    lines = readlines(filename)

    if 'v' ∈ first(lines)
        det_id, version = map(x->parse(Int,x), split(first(lines), 'v'))
        n_doms = parse(Int, lines[4])
        idx = 5
    else
        det_id, n_doms = map(x->parse(Int,x), split(first(lines)))
        version = 1
        idx = 2
    end

    pos = Dict{Int32,Vector{KM3NeT.Position}}()
    dir = Dict{Int32,Vector{KM3NeT.Direction}}()
    t0s = Dict{Int32,Vector{Int32}}()
    dus = Dict{Int32,UInt8}()
    floors = Dict{Int32,UInt8}()

    for dom ∈ 1:n_doms
        dom_id, du, floor, n_pmts = map(x->parse(Int,x), split(lines[idx]))
        pos[dom_id] = Vector{KM3NeT.Position}()
        dir[dom_id] = Vector{KM3NeT.Direction}()
        t0s[dom_id] = Vector{Int32}()
        dus[dom_id] = du
        floors[dom_id] = floor

        for pmt in 1:n_pmts
            l = split(lines[idx+pmt])
            pmt_id = parse(Int,first(l))
            x, y, z, dx, dy, dz = map(x->parse(Float64, x), l[2:7])
            t0 = parse(Int,first(l[8]))
            push!(pos[dom_id], Position(x, y, z))
            push!(dir[dom_id], Direction(dx, dy, dz))
            push!(t0s[dom_id], t0)
        end
        idx += n_pmts + 1
    end

    Calibration(det_id, pos, dir, t0s, dus, floors)
end

function calibrate(hits::Vector{RawHit}, calibration::Calibration)
    calibrated_hits = Vector{CalibratedHit}()
    for hit in hits
        dom_id = hit.dom_id
        t = hit.t
        channel_id = hit.channel_id
        triggered = hit.triggered
        tot = hit.tot
        pos = calibration.pos[dom_id][channel_id+1]
        dir = calibration.dir[dom_id][channel_id+1]
        t0 = calibration.t0[dom_id][channel_id+1]
        du = calibration.du[dom_id]
        floor = calibration.floor[dom_id]
        c_hit = CalibratedHit(channel_id, dom_id, du, floor, t, tot,
                              triggered, pos, dir, t0)
        push!(calibrated_hits, c_hit)
    end
    calibrated_hits
end


function read_event_info(fobj::HDF5.HDF5File)
    event_info = Dict{Int32,EventInfo}()
    entries = read(fobj, "event_info")
    for entry in entries
        e = EventInfo(entry.data...)
        event_info[e.event_id] = e
    end
    event_info
end


function read_event_info(filename::AbstractString)
    event_info = h5open(filename) do file
        read_event_info(file)
    end
    event_info
end

# Event Loop
struct Event
    id::Integer
    info::EventInfo
    hits::Vector{RawHit}
#    mc_hits::Vector{McHit}
    mc_tracks::Vector{Track}
end


Base.show(io::IO, e::Event) = begin
    print(io, "Event $(e.id): $(length(e.hits)) hits, $(length(e.mc_tracks)) MC tracks")
end


mutable struct EventReaderState
    fobj::HDF5.HDF5File
    event_id::Unsigned
end


struct EventReader
    filename::AbstractString
    n_events::Unsigned
    event_info::Dict{Int32,KM3NeT.EventInfo}
    hit_indices::Vector{Tuple{Int64,Int64}}
    tracks::Dict{Int32,Vector{Track}}
    load_tracks::Bool

    EventReader(filename; load_tracks=false) = begin
        fobj = h5open(filename)
        n = length(read_event_info(fobj))
        event_info = read_event_info(fobj)
        hit_indices = read_indices(fobj, "/hits")
#       mc_hit_indices = read_indices(fobj, "/mc_hits")
        if load_tracks
            tracks = read_tracks(fobj)
        else
            tracks = Dict{Int32,Vector{Track}}()
        end
        close(fobj)
        new(filename, n, event_info, hit_indices, tracks, load_tracks)
    end
end


Base.start(E::EventReader) = begin
    fobj = h5open(E.filename)
    event_id = 0
    return EventReaderState(fobj, event_id)
end

Base.next(E::EventReader, s) = begin
    event_id = s.event_id
    idx = E.hit_indices[s.event_id+1][1]
    n_hits = E.hit_indices[s.event_id+1][2]
    s.event_id += 1
    if E.load_tracks
        tracks = E.tracks[event_id]
    else
        tracks = Vector{Track}()
    end
    event = Event(event_id, E.event_info[event_id],
                  read_hits(s.fobj, idx, n_hits), tracks)
    (event, s)
end

Base.show(io::IO, e::EventReader) = begin
    print(io, "EventReader from file: $(e.filename) with $(e.n_events) events.")
end

Base.done(E::EventReader, s) = begin
    if(s.event_id >= E.n_events)
        close(s.fobj)
        return true
    end
    return false
end

Base.getindex(E::EventReader, event_id::Int64) = begin
    idx = E.hit_indices[event_id+1][1]
    n_hits = E.hit_indices[event_id+1][2]
    if E.load_tracks
        tracks = E.tracks[event_id]
    else
        tracks = Vector{Track}()
    end
    fobj = h5open(E.filename)
    event = KM3NeT.Event(event_id, E.event_info[event_id],
                         read_hits(fobj, idx, n_hits), tracks)
    close(fobj)
    return event
end

Base.getindex(E::EventReader, event_id) = begin
    fobj = h5open(E.filename)
    events = Vector{Event}()
    for i in event_id
        idx = E.hit_indices[i+1][1]
        n_hits = E.hit_indices[i+1][2]
        if E.load_tracks
            tracks = E.tracks[i]
        else
            tracks = Vector{Track}()
        end
        event = KM3NeT.Event(i, E.event_info[i],
                             read_hits(fobj, idx, n_hits), tracks)
        push!(events, event)
    end
    close(fobj)
    return events
end

Base.eltype(::Type{EventReader}) = Event
Base.length(E::EventReader) = E.n_events
Base.endof(E::EventReader) = E.n_events - 1

# Utility
rows(x) = (x[i, :] for i in indices(x,1))


# Math
Base.angle(d1::Direction, d2::Direction) = acos(dot(d1/norm(d1), d2/norm(d2)))
Base.angle(a::T, b::T) where {T<:Union{Hit, PMT, Track}} = Base.angle(a.dir, b.dir)
Base.angle(a::FieldVector{3}, b::Union{Hit, PMT, Track}) = Base.angle(a, b.dir)
Base.angle(a::Union{Hit, PMT, Track}, b::FieldVector{3}) = Base.angle(a.dir, b)

function matrix(v::Vector)
    m = length(v)
    n = length(v[1])

    M = zeros(m, n)
    i = 1
    for j ∈ 1:n
        for k ∈ 1:m
            M[i] = v[k][j]
            i += 1
        end
    end
    M
end


function svdfit(M)
    com = mean(M, 1)
    subtr = M .- com
    U, S, V = svd(subtr)
    V[:, 1]
end


end # module
