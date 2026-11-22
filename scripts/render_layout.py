# KLayout batch script: render the final GDS to a PNG.
# klayout -zz -rd gds=<in.gds> -rd png=<out.png> [-rd lyp=<layers.lyp>] -r scripts/render_layout.py
import pya

view = pya.LayoutView()
view.load_layout(gds, True)  # noqa: F821  (set with -rd)
try:
    if lyp:  # noqa: F821
        view.load_layer_props(lyp)  # noqa: F821
except NameError:
    pass
view.max_hier()
view.zoom_fit()
view.save_image(png, 1600, 1600)  # noqa: F821
print(f"wrote {png}")  # noqa: F821
