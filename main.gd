extends Node3D
## 入口：只做装配，不含任何逻辑。
## 场景树：Main → GameApp（core Sim + view + ui 全部由 GameApp 自建）

var app: GameApp


func _ready() -> void:
	app = GameApp.new()
	app.name = "GameApp"
	add_child(app)
