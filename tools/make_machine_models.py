"""Rebuild the chain-reaction demo's display models with Blender in background mode.

Run from the project directory: blender -b -P tools/make_machine_models.py
Dimensions and attachment points use the scene's Godot axes.
"""
from math import cos, pi, sin
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


DEST = Path(__file__).resolve().parents[1] / "demo/machine/models"
DEST.mkdir(exist_ok=True, parents=True)
bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, hex_color, metallic, roughness):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    rgb = [int(hex_color[k:k + 2], 16) / 255 for k in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*linear, 1)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


enamel = material("Petrol • baked enamel", "17635f", .42, .25)
steel = material("Graphite • gunmetal", "414948", .72, .28)
black = material("Recess • charcoal", "172020", .18, .44)
brass = material("Brushed champagne brass", "dfad66", .76, .24)
copper = material("Burnished copper", "c88556", .64, .31)
ivory = material("Warm ceramic", "eee2c8", .13, .29)
coral = material("Vermilion lacquer", "d65b3c", .37, .25)
yellow = material("Marigold enamel", "f9ad35", .38, .24)
wood = material("Walnut edge", "76482e", .10, .49)
slate = material("Green linoleum", "29504f", .12, .46)


def pt(x, y, z):
    return Vector((x, -z, y))


def surface(obj, name, mat):
    obj.name = name
    obj.data.materials.append(mat)
    return obj


def bevel(obj, width):
    mod = obj.modifiers.new("Radiused edges", "BEVEL")
    mod.width = width
    mod.segments = 3
    mod.harden_normals = True
    weighted = obj.modifiers.new("Face normals", "WEIGHTED_NORMAL")
    weighted.keep_sharp = True


def box(name, pos, dims, mat, radius=.02):
    bpy.ops.mesh.primitive_cube_add(size=1, location=pt(*pos))
    obj = bpy.context.object
    obj.dimensions = (dims[0], dims[2], dims[1])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if radius: bevel(obj, radius)
    return surface(obj, name, mat)


def cylinder(name, a, b, radius, mat, sides=40, edge=.006):
    start, end = pt(*a), pt(*b)
    axis = end - start
    bpy.ops.mesh.primitive_cylinder_add(vertices=sides, radius=radius, depth=axis.length, location=(start+end)*.5)
    obj = bpy.context.object
    obj.rotation_euler = axis.to_track_quat("Z", "Y").to_euler()
    for poly in obj.data.polygons: poly.use_smooth = len(poly.vertices) == 4
    if edge: bevel(obj,edge)
    return surface(obj,name,mat)


def bolt(x,y,z,r=.047):
    cylinder("Hex head",(x,y,z-.016),(x,y,z+.007),r,brass,6,.002)
    cylinder("Socket",(x,y,z+.007),(x,y,z+.009),r*.41,black,6,0)


def lettering(name, text, pos, height, mat):
    glyphs = bpy.data.curves.new(name, "FONT")
    glyphs.body = text
    glyphs.size = height
    glyphs.space_character = 1.23
    glyphs.align_y = "CENTER"
    obj = bpy.data.objects.new(name, glyphs)
    bpy.context.collection.objects.link(obj)
    obj.location = pt(*pos)
    obj.rotation_euler.x = pi / 2
    obj.data.materials.append(mat)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.convert(target="MESH")


def profile(name, rings, materials):
    """Turn a cross-section about the gently inclined toy barrel axis."""
    n=72
    vertices=[]; faces=[]; slots=[]
    for x,rad,_ in rings:
        cy=.45+.09*x
        for i in range(n):
            phi=2*pi*i/n
            vertices.append(pt(x,cy+rad*cos(phi),rad*sin(phi)))
    for j in range(len(rings)-1):
        for i in range(n):
            a=j*n+i; b=j*n+(i+1)%n
            faces.append((a,b,b+n,a+n)); slots.append(rings[j][2])
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(vertices,[],faces);mesh.update()
    obj=bpy.data.objects.new(name,mesh);bpy.context.collection.objects.link(obj)
    for m in materials: mesh.materials.append(m)
    for poly,slot in zip(mesh.polygons,slots):
        poly.use_smooth=True;poly.material_index=slot


def export(name):
    bpy.ops.object.select_all(action="SELECT")
    for obj in list(bpy.context.selected_objects):
        bpy.context.view_layer.objects.active=obj
        for mod in list(obj.modifiers): bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.ops.object.join()
    obj=bpy.context.object
    bpy.context.scene.cursor.location=(0,0,0)
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    obj.name=name
    bpy.ops.export_scene.gltf(filepath=str(DEST/(name+".glb")), export_format="GLB",
                              use_selection=True, export_animations=False, export_cameras=False,
                              export_lights=False, export_extras=False)
    bpy.ops.object.delete()


def cannon():
    box("Plinth",(0,-.13,0),(1.18,.15,1.00),black,.045)
    box("Flanged foot",(0,-.065,0),(1.10,.09,.94),brass,.026)
    box("Swivel platform",(0,-.006,0),(1.00,.11,.85),enamel,.06)
    for z in (-.30,.30):
        box("Yoke",(-.1,.16,z),(.63,.43,.13),enamel,.074)
        cylinder("Trunnion",(-.12,.28,z-.085),(-.12,.28,z+.086),.152,brass,48,.012)
        cylinder("Retainer",(-.12,.28,z+.08),(-.12,.28,z+.095),.104,steel,48,.006)
        if z>0:bolt(-.12,.28,z+.101,.068)
    profile("Spun barrel",[
        (-.62,.016,1),(-.60,.18,1),(-.54,.266,0),(-.49,.293,0),(-.45,.297,0),
        (-.43,.326,1),(-.40,.332,1),(-.35,.332,1),(-.334,.303,0),(-.29,.298,0),
        (-.23,.306,0),(.08,.306,0),(.10,.317,1),(.14,.318,1),(.17,.275,0),
        (.23,.262,0),(.44,.234,0),(.46,.247,1),(.50,.245,1),(.52,.23,0),
        (.56,.23,0),(.60,.268,1),(.64,.294,1),(.73,.294,1),(.75,.283,1),
        (.755,.19,1),(.72,.174,2),(.55,.161,2),(.38,.145,2),(.37,.001,2)
    ],[enamel,brass,black])
    for i in range(16):
        th=2*pi*i/16
        cylinder("Breech fluting",(-.292,.425+.303*cos(th),.303*sin(th)),(.077,.455+.303*cos(th),.303*sin(th)),.012,steel,12,.002)
    for x in (-.37,.37):
        for z in (-.35,.35):
            cylinder("Mount screw",(x,.045,z),(x,.075,z),.036,brass,6,.002)
    export("cannon")


def tiles():
    for name,mat in (("domino-jade",enamel),("domino-coral",coral)):
        box("Enamel tile",(0,0,0),(.12,.90,.70),mat,.044)
        for side in (-1,1):
            x=side*.0605
            box("Dividing rule",(x,0,0),(.005,.014,.53),brass,.0025)
            for y,z in ((.25,-.14),(.16,.15),(-.15,-.15),(-.25,0),(-.34,.15)):
                cylinder("Inset pip",(x,y,z),(x+side*.004,y,z),.048,ivory,24,.001)
        # A gold edge inlay stays legible in the nearly side-on gameplay view.
        box("Edge inlay",(0,.29,.349),(.080,.042,.008),brass,.003)
        export(name)
    for name,mat in (("block-ivory",ivory),("block-coral",coral),("block-jade",enamel)):
        box("Ceramic block",(0,0,0),(.495,.495,.495),mat,.046)
        # Four brass locator studs on the face that looks at the camera.
        for x in (-.147,.147):
            for y in (-.147,.147):
                cylinder("Face stud",(x,y,.245),(x,y,.249),.022,brass,16,0)
        box("Inlaid edge",(0,.235,0),(.437,.013,.453),brass,.005)
        export(name)


def display():
    box("Walnut surround",(7.5,-.38,-.3),(29.7,.62,9.9),wood,.17)
    box("Shadow line",(7.5,-.122,-.3),(29.62,.11,9.88),black,.04)
    box("Brass perimeter",(7.5,-.081,-.3),(29.57,.065,9.86),brass,.026)
    box("Linoleum top",(7.5,-.043,-.3),(29.54,.086,9.82),slate,.036)
    # Flush calibration lines in the table read as joinery, especially in close-ups.
    for z in (-1.0,1.00):
        box("Track datum",(3.2,.002,z),(19.6,.004,.014),brass,.002)
        for i in range(40):
            x=-6.45+.50*i
            size=.15 if i%2==0 else .07
            box("Graduation",(x,.004,z+(.5*size if z>0 else -.5*size)),(.014,.005,size),brass,.001)
    for x in (-5.1,-3.14,-.1,1.8,3.6,5.5,7.4,9.1):
        box("Post footing",(x,.055,-.48),(.52,.11,.45),steel,.033)
        for off in (-.175,.175):
            cylinder("Footing screw",(x+off,.10,-.365),(x+off,.13,-.365),.035,brass,6,.003)
    for x0,x1,y0,y1 in ((-5.20,-3.0,5.28,4.62),(-2.95,-.60,2.92,2.32),(1.60,3.60,1.47,1.12),(3.6,9.3,1.12,1.12)):
        for z in (-.595,.595):
            cylinder("Edge nosing",(x0,y0,z),(x1,y1,z),.032,brass,20,.004)
    for a,b in ((3.65,5.45),(5.55,7.35),(7.45,9.05)):
        cylinder("Diagonal stay",(a,.19,-.48),(b,.98,-.48),.049,steel,16,.006)
        cylinder("Diagonal stay",(a,.98,-.48),(b,.19,-.48),.043,steel,16,.006)
    box("Instrument plate",(6.45,.94,.60),(5.67,.22,.064),enamel,.027)
    for x in (3.71,9.19):bolt(x,.94,.646,.045)
    lettering("Relay legend", "DOMINO   RELAY", (3.91,.94,.636), .124, ivory)
    lettering("Station number", "04", (8.82,.94,.636), .135, brass)
    for x in [-5.9,-3,0,3,6,9,12,15,18,21]:bolt(x,-.39,4.657,.080)
    export("display-table")


cannon()
tiles()
display()
