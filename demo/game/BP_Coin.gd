# @blueprint v1 - generated from a Blueprint graph. Edit it in the Blueprint editor, not by hand.
class_name BP_Coin
extends Area2D
## Gives its value to the player that touches it, then removes itself.

## Score given when collected.
@export var value: int = 5


func _ready() -> void:
	body_entered.connect(_on_self_body_entered)


func _on_self_body_entered(body: Node2D) -> void:
	var as_bp_player_4: BP_Player = body as BP_Player
	if as_bp_player_4 != null:
		as_bp_player_4.add_score(value)
		self.queue_free()


#region Blueprint graph data (machine-written; edit this file in the Blueprint editor)
#~ {
#~ 	"class_name": "BP_Coin",
#~ 	"description": "Gives its value to the player that touches it, then removes itself.",
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
#~ 					"id": 3,
#~ 					"kind": "signal_event",
#~ 					"p": {
#~ 						"args": [
#~ 							[
#~ 								"body",
#~ 								"Node2D"
#~ 							]
#~ 						],
#~ 						"cls": "Area2D",
#~ 						"path": ".",
#~ 						"signal": "body_entered"
#~ 					},
#~ 					"x": 80.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 4,
#~ 					"kind": "cast",
#~ 					"p": {
#~ 						"cls": "BP_Player"
#~ 					},
#~ 					"x": 380.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 5,
#~ 					"kind": "var_get",
#~ 					"p": {
#~ 						"name": "value"
#~ 					},
#~ 					"x": 520.0,
#~ 					"y": 280.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 6,
#~ 					"kind": "call",
#~ 					"p": {
#~ 						"cls": "BP_Player",
#~ 						"method": "add_score"
#~ 					},
#~ 					"x": 700.0,
#~ 					"y": 80.0
#~ 				},
#~ 				{
#~ 					"d": {},
#~ 					"id": 7,
#~ 					"kind": "tpl",
#~ 					"p": {
#~ 						"id": "destroy_node"
#~ 					},
#~ 					"x": 980.0,
#~ 					"y": 80.0
#~ 				}
#~ 			],
#~ 			"outputs": [],
#~ 			"pure": false,
#~ 			"sx": 0.0,
#~ 			"sy": 0.0,
#~ 			"wires": [
#~ 				[
#~ 					3,
#~ 					"then",
#~ 					4,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					3,
#~ 					"p_body",
#~ 					4,
#~ 					"obj"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"then",
#~ 					6,
#~ 					"exec"
#~ 				],
#~ 				[
#~ 					4,
#~ 					"as",
#~ 					6,
#~ 					"target"
#~ 				],
#~ 				[
#~ 					5,
#~ 					"value",
#~ 					6,
#~ 					"a0"
#~ 				],
#~ 				[
#~ 					6,
#~ 					"then",
#~ 					7,
#~ 					"exec"
#~ 				]
#~ 			],
#~ 			"zoom": 1.0
#~ 		}
#~ 	],
#~ 	"parent": "Area2D",
#~ 	"tool": false,
#~ 	"variables": [
#~ 		{
#~ 			"category": "",
#~ 			"default": "5",
#~ 			"export": true,
#~ 			"name": "value",
#~ 			"spawn": true,
#~ 			"tooltip": "Score given when collected.",
#~ 			"type": "int"
#~ 		}
#~ 	],
#~ 	"version": 1
#~ }
#endregion
