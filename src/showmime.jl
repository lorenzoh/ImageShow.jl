###
### show as MIME type
###
using FileIO: @format_str
using Base64: Base64EncodePipe
import Base.showable

# This is used by IJulia (for example) to display images

# showable to PNG if 2D colorant array
# issue #12 -- 0 length image isn't showable
showable(::MIME"image/png", img::AbstractMatrix{C}) where {C<:Colorant} = _length1(img) > 0

# Colors.jl turns on SVG display of colors, which leads to poor
# performance and weird spacing if you're displaying images. We need
# to disable that here.
# See https://github.com/JuliaLang/IJulia.jl/issues/229 and Images #548
showable(::MIME"image/svg+xml", img::AbstractMatrix{C}) where {C<:Color} = false

# Really large images can make display very slow, so we shrink big
# images.  Conversely, tiny images don't show up well, so in such
# cases we repeat pixels.
function Base.show(io::IO, mime::MIME"image/png", img::AbstractMatrix{C};
#                   minpixels=10^3, maxpixels=10^5,
                   minpixels=10^4, maxpixels=10^6,
                   # Jupyter seemingly can't handle 16-bit colors:
                   mapi=x->mapc(N0f8, clamp01nan(csnormalize(x)))) where C<:Colorant
    img = enforce_standard_dense_array(img)
    if !get(io, :full_fidelity, false)
        while _length1(img) > maxpixels
            img = restrict(img)  # big images
        end
        npix = _length1(img)
        if npix < minpixels
            # Tiny images
            fac = ceil(Int, sqrt(minpixels/npix))
            r = ones(Int, ndims(img))
            r[[coords_spatial(img)...]] .= fac
            img = repeat(img, inner=r)
        end
        FileIO.save(_format_stream(format"PNG", io), img, mapi=mapi)
    else
        FileIO.save(_format_stream(format"PNG", io), img)
    end
end

Base.show(io::IO, mime::MIME"image/png", img::OffsetArray{C}; kwargs...) where C<:Colorant =
    show(io, mime, parent(img); kwargs...)

# Not all colorspaces are supported by all backends, so reduce types to a minimum
csnormalize(c::AbstractGray) = Gray(c)
csnormalize(c::Color) = RGB(c)
csnormalize(c::Colorant) = RGBA(c)

# Unless we have PNG IO backend that works on generic array types, we have to eagerly
# convert it to dense array types
# On performance: if the array type has efficient convert method to Array then this is
# almost a no-op
function enforce_standard_dense_array(A::AbstractArray)
    if Base.has_offset_axes(A)
        convert(Array, OffsetArrays.no_offset_view(A))
    else
        convert(Array, A)
    end
end
enforce_standard_dense_array(A::DenseArray) = A
enforce_standard_dense_array(A::OffsetArray) = enforce_standard_dense_array(parent(A))
# TODO(johnnychen94): Uncomment this when we set direct dependency to PNGFiles.
# enforce_standard_dense_array(A::IndirectArray) = A # PNGFiles has built-in support for IndirectArray.

const ColorantMatrix{T<:Colorant} = AbstractMatrix{T}

function _show_odd(io::IO, m::MIME"text/html", imgs::AbstractArray{T, 1}) where T<:ColorantMatrix
    # display a vector of images in a row
    for j in eachindex(imgs)
        write(io, "<td style='text-align:center;vertical-align:middle; margin: 0.5em;border:1px #90999f solid;border-collapse:collapse'>")
        show_element(IOContext(io, :thumbnail => true), imgs[j])
        write(io, "</td>")
    end
end

function _show_odd(io::IO, m::MIME"text/html", imgs::AbstractArray{T, N}) where {T<:ColorantMatrix, N}
    colons = ([Colon() for i=1:(N-1)]...,)
    for i in axes(imgs, N)
        write(io, "<td style='text-align:center;vertical-align:middle; margin: 0.5em;border:1px #90999f solid;border-collapse:collapse'>")
        _show_even(io, m, view(imgs, colons..., i)) # show even
        write(io, "</td>")
    end
end

function _show_even(io::IO, m::MIME"text/html", imgs::AbstractArray{T, N}, center=true) where {T<:ColorantMatrix, N}
    colons = ([Colon() for i=1:(N-1)]...,)
    centering = center ? " style='margin: auto'" : ""
    write(io, "<table$centering>")
    write(io, "<tbody>")
    for i in axes(imgs, N)
        write(io, "<tr>")
        _show_odd(io, m, view(imgs, colons..., i)) # show odd
        write(io, "</tr>")
    end
    write(io, "</tbody>")
    write(io, "</table>")
end

function Base.show(io::IO, m::MIME"text/html", imgs::AbstractArray{T, N}) where {T<:ColorantMatrix, N}
    imgs = permutedims(imgs, N:-1:1)
    if N % 2 == 1
        write(io, "<table>")
        write(io, "<tbody>")
        write(io, "<tr>")
        _show_odd(io, m, imgs) # Stack horizontally
        write(io, "</tr>")
        write(io, "</tbody>")
        write(io, "</table>")
        if N == 1
            write(io, "<div><small>(a vector displayed as a row to save space)</small></div>")
        end
    else
        _show_even(io, m, imgs, false) # Stack vertically
    end
end

function downsize_for_thumbnail(img, w, h)
    a,b=size(img)
    a > 2w && b > 2h ?
        downsize_for_thumbnail(_restrict1(img), w, h) : img
end

function show_element(io::IOContext, img)
    io2=IOBuffer()
    w,h=get(io, :thumbnailsize, (100,100))
    im_resized = downsize_for_thumbnail(img, w, h)
    thumbnail_style = get(io, :thumbnail, false) ? "max-width: $(w)px; max-height:$(h)px;" : ""
    b64pipe=Base64EncodePipe(io2)
    write(io,"<img style='$(thumbnail_style)display:inline' src=\"data:image/png;base64,")
    show(b64pipe, MIME"image/png"(), im_resized)
    write(io, read(seekstart(io2)))
    write(io,"\">")
end

_length1(A::AbstractArray) = length(eachindex(A))
_length1(A) = length(A)



const _HTML_IMAGE_MIMES = [
    MIME("image/jpg"),
    MIME("image/png"),
]

function Base.show(io::IO, ::MIME"text/html", img::ColorantMatrix)
    _show_image_html(io, _HTML_IMAGE_MIMES, img)
end

function _show_image_html(io, mimes::Vector{<:MIME}, x)
    for mime in mimes
        if showable(mime, x)
            _show_image_html(io, mime, x)
            break
        end
    end
end

function _show_image_html(io, mime::MIME{Name}, x) where Name
    buf = IOBuffer()
    show(buf, mime, x)
    print(io, """<img src="data:""", Name, ";base64,", Base64.base64encode(take!(buf)), "\" />")
end
