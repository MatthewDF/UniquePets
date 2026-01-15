
# Unique Pets by Mazu

This addon for Ashita allows you to set a model for your pet and for others', while keeping your change unique. That means you can replace your Wyvern, for example, but every other Wyvern will remain unchanged.

## Installation

Place the UniquePets folder in your HorizonXI\Game\addons folder, then add the addon to your default.txt in HorizonXI\Game\scripts.

## Setup

UniquePets requires just a few things from you inside of the Settings.Lua file: Your pet name, and the model number to replace it with.

You may also replace other player's pet models (or they may share their changes with you!), in which case you'll also use their name.

Look at the settings.lua for examples.

## Finding Model Numbers

I've included some model numbers I've tested in the ModelNumbersTested.txt folder that you can use, but you can also use the ModelSniffer.Lua addon to locate more. Warning: It's very verbose.

## ***About Animations and Models***
You should know that there's no harm in replacing models for your characters or pets, but it *can* look funny if the pet and the model aren't well suited to each other. This is **most evident** on Avatars and their Bloodpacts. Keep that in mind for best results <3

## Tips and Tricks
* If you know what you want to make your pet look like, use the ModelSniffer while near that creature in-game to get its model number, then use that for your model swap.
* With the addon loaded, use /addon reload UniquePets to quickly refresh it once you make a change in your Settings.Lua - Otherwise it won't show!
