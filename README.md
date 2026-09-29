# Spoil

Spoil is the file manager of [milk](https://github.com/mirvoxtm/milk). It opens with Super+E,
follows milk's theme from `milk.json`, and keeps its look close to milk's bar.

milk's installer fetches and builds Spoil next to milk. To build it by hand, clone it beside your
milk folder and run the build:

```sh
git clone https://github.com/mirvoxtm/spoil.git   # next to the milk folder
cd spoil
./build.sh
./spoil [folder]
```

## Warning

Spoil will run fine in other WMs and stuff, however features like the alacritty and mpv integration directly on the explorer will not be available.