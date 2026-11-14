# @blueprint v1 - generated from a Blueprint graph. Edit it in the Blueprint editor, not by hand.
class_name BP_ItemRow
extends Resource
## A structure of fields, like an Unreal struct. Use it as the rows of a Data Table, or make single assets of it in the Inspector.

## Shown to the player.
@export var display_name: String = ""
## Picture for menus and the HUD.
@export var icon: Texture2D
## What it is worth.
@export var value: int = 0
## How heavy it is.
@export var weight: float = 1.0
## Can several share one inventory slot?
@export var stackable: bool = true


#region Blueprint graph data (machine-written; edit this file in the Blueprint editor)
#~ {
#~ 	"class_name": "BP_ItemRow",
#~ 	"description": "A structure of fields, like an Unreal struct. Use it as the rows of a Data Table, or make single assets of it in the Inspector.",
#~ 	"dispatchers": [],
#~ 	"graphs": [
#~ 		{
#~ 			"id": 1,
#~ 			"inputs": [],
#~ 			"kind": "event",
#~ 			"locals": [],
#~ 			"name": "EventGraph",
#~ 			"next_id": 2,
#~ 			"nodes": [
#~ 				{
#~ 					"d": {},
#~ 					"id": 1,
#~ 					"kind": "comment",
#~ 					"p": {
#~ 						"h": 160.0,
#~ 						"text": "A data asset only needs variables: each one is a field. Rename, add and remove them in My Blueprint.",
#~ 						"w": 1000.0
#~ 					},
#~ 					"x": 40.0,
#~ 					"y": 40.0
#~ 				}
#~ 			],
#~ 			"outputs": [],
#~ 			"pure": false,
#~ 			"sx": 0.0,
#~ 			"sy": 0.0,
#~ 			"wires": [],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"library": "data",
#~ 	"parent": "Resource",
#~ 	"tool": false,
#~ 	"variables": [
#~ 		{
#~ 			"category": "",
#~ 			"default": "",
#~ 			"export": true,
#~ 			"name": "display_name",
#~ 			"tooltip": "Shown to the player.",
#~ 			"type": "String"
#~ 		},
#~ 		{
#~ 			"category": "",
#~ 			"default": "",
#~ 			"export": true,
#~ 			"name": "icon",
#~ 			"tooltip": "Picture for menus and the HUD.",
#~ 			"type": "Texture2D"
#~ 		},
#~ 		{
#~ 			"category": "",
#~ 			"default": "0",
#~ 			"export": true,
#~ 			"name": "value",
#~ 			"tooltip": "What it is worth.",
#~ 			"type": "int"
#~ 		},
#~ 		{
#~ 			"category": "",
#~ 			"default": "1.0",
#~ 			"export": true,
#~ 			"name": "weight",
#~ 			"tooltip": "How heavy it is.",
#~ 			"type": "float"
#~ 		},
#~ 		{
#~ 			"category": "",
#~ 			"default": "true",
#~ 			"export": true,
#~ 			"name": "stackable",
#~ 			"tooltip": "Can several share one inventory slot?",
#~ 			"type": "bool"
#~ 		}
#~ 	],
#~ 	"version": 1
#~ }
#endregion
