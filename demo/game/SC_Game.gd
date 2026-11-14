# @schematic v1 - generated from a Schematic graph. Edit it in the Schematic editor, not by hand.
class_name SC_Game
extends Node2D
## Spawns a row of coins worth 10, 20 and 30.


func _ready() -> void:
	for i_3 in range(0, 3):
		var spawned_4: SC_Coin = (preload("res://demo/game/coin.tscn") as PackedScene).instantiate() as SC_Coin
		spawned_4.set(&"value", ((i_3 + 1) * 10))
		add_child(spawned_4)
		spawned_4.position = Vector2(((i_3 * 80) + 200), 0.0)


#region Schematic graph data (machine-written; edit this file in the Schematic editor)
#~ {
#~ 	"class_name": "SC_Game",
#~ 	"description": "Spawns a row of coins worth 10, 20 and 30.",
#~ 	"dispatchers": [],
#~ 	"graphs": [
#~ 		{
#~ 			"id": 1,
#~ 			"inputs": [],
#~ 			"kind": "event",
#~ 			"locals": [],
#~ 			"name": "EventGraph",
#~ 			"next_id": 11,
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
#~ 					"d": {
#~ 						"last": "2"
#~ 					},
#~ 					"id": 3,
#~ 					"kind": "for",
#~ 					"p": {},
#~ 					"x": 320.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"scene": "preload(\"res://demo/game/coin.tscn\")"
#~ 					},
#~ 					"id": 4,
#~ 					"kind": "spawn",
#~ 					"p": {
#~ 						"xt": "Transform2D"
#~ 					},
#~ 					"x": 620.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"a1": "1"
#~ 					},
#~ 					"id": 5,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "+"
#~ 					},
#~ 					"x": 320.0,
#~ 					"y": 360.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"a1": "10"
#~ 					},
#~ 					"id": 6,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "*"
#~ 					},
#~ 					"x": 470.0,
#~ 					"y": 360.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"a1": "80"
#~ 					},
#~ 					"id": 7,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "*"
#~ 					},
#~ 					"x": 620.0,
#~ 					"y": 520.0
#~ 				},
#~ 				{
#~ 					"d": {
#~ 						"a1": "200"
#~ 					},
#~ 					"id": 8,
#~ 					"kind": "math",
#~ 					"p": {
#~ 						"n": 2,
#~ 						"op": "+"
#~ 					},
#~ 					"x": 770.0,
#~ 					"y": 520.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 9,
#~ 					"kind": "ctor",
#~ 					"p": {
#~ 						"i": 3,
#~ 						"type": "Vector2"
#~ 					},
#~ 					"x": 930.0,
#~ 					"y": 500.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 10,
#~ 					"kind": "set_prop",
#~ 					"p": {
#~ 						"cls": "Node2D",
#~ 						"prop": "position"
#~ 					},
#~ 					"x": 1160.0,
#~ 					"y": 80.0
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
#~ 					"body",
#~ 					4,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"index",
#~ 					5,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"ret",
#~ 					6,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					6,
#~ 					"ret",
#~ 					4,
#~ 					"x_value"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"index",
#~ 					7,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					7,
#~ 					"ret",
#~ 					8,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					8,
#~ 					"ret",
#~ 					9,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"then",
#~ 					10,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"ret",
#~ 					10,
#~ 					"target"
#~ 				],
#~ 				[
#~ 					9,
#~ 					"ret",
#~ 					10,
#~ 					"value"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"parent": "Node2D",
#~ 	"tool": false,
#~ 	"variables": [],
#~ 	"version": 1
#~ }
#endregion
