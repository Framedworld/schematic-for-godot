# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_Shop
extends Node


func _ready() -> void:
	var row_3: SC_ItemRow = preload("res://demo/data/DT_Items.tres").get_row(&"sword") as SC_ItemRow
	if row_3 != null:
		print("{name} costs {price}".format({"name": row_3.display_name, "price": row_3.value}))
	else:
		print("No such item")


func _process(delta: float) -> void:
	pass


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {
#~ 	"class_name": "SC_Shop",
#~ 	"description": "",
#~ 	"dispatchers": [],
#~ 	"graphs": [
#~ 		{
#~ 			"id": 1,
#~ 			"inputs": [],
#~ 			"kind": "event",
#~ 			"locals": [],
#~ 			"name": "EventGraph",
#~ 			"next_id": 8,
#~ 			"nodes": [
#~ 				{
#~ 					"d": {},
#~ 					"id": 1,
#~ 					"kind": "event",
#~ 					"p": {
#~ 						"name": "_ready"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 2,
#~ 					"kind": "event",
#~ 					"p": {
#~ 						"name": "_process"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 260.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"row": "&\"sword\""
#~ 					},
#~ 					"id": 3,
#~ 					"kind": "table_row",
#~ 					"p": {
#~ 						"cls": "SC_ItemRow",
#~ 						"table": "res://demo/data/DT_Items.tres"
#~ 					},
#~ 					"x": 340.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 4,
#~ 					"kind": "break",
#~ 					"p": {
#~ 						"type": "SC_ItemRow"
#~ 					},
#~ 					"x": 680.0,
#~ 					"y": 240.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 5,
#~ 					"kind": "format",
#~ 					"p": {
#~ 						"text": "{name} costs {price}"
#~ 					},
#~ 					"x": 980.0,
#~ 					"y": 240.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 6,
#~ 					"kind": "print",
#~ 					"p": {},
#~ 					"x": 1280.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"text": "\"No such item\""
#~ 					},
#~ 					"id": 7,
#~ 					"kind": "print",
#~ 					"p": {},
#~ 					"x": 680.0,
#~ 					"y": 460.0
#~ 				}
#~ 			],
#~ 			"outputs": [],
#~ 			"pure": false,
#~ 			"sx": 0.0,
#~ 			"sy": 0.0,
#~ 			"wires": [
#~ 				[
#~ 					1,
#~ 					"then",
#~ 					3,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"found",
#~ 					6,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"not_found",
#~ 					7,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"row_out",
#~ 					4,
#~ 					"v"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"m_display_name",
#~ 					5,
#~ 					"f_name"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"m_value",
#~ 					5,
#~ 					"f_price"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"ret",
#~ 					6,
#~ 					"text"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"parent": "Node",
#~ 	"tool": false,
#~ 	"variables": [],
#~ 	"version": 1
#~ }
#endregion
