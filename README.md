# Unique Pets by Mazu
<p align="center">
<img width="532" height="473" alt="Screenshot 2026-02-16 150136" src="https://github.com/user-attachments/assets/444877a0-d581-4627-8a7d-7a4bda5c0665" />
</p>

This addon for Ashita allows you to set a model for your pet and for others', while keeping your change unique. That means you can replace your Wyvern, for example, but every other Wyvern will remain unchanged.

<p align="center">
<img width="573" height="410" alt="Screenshot 2026-02-04 204001" src="https://github.com/user-attachments/assets/b0306640-1b1f-403e-b7ee-929450d81644" />
</p>

---

## Installation

Place UniquePets.lua in a folder named 'UniquePets' inside your HorizonXI\Game\addons folder, then add the addon to your default.txt in HorizonXI\Game\scripts.

In-game, be sure to type `/addon load UniquePets` to activate it for the first time, if needed.

## How to Use
Load the addon and in-game type `/uniquepets` or `/upets` to bring up the window.
<img width="588" height="474" alt="image" src="https://github.com/user-attachments/assets/4e92cab4-575d-429c-8450-3a14a152db08" />

Add a pet name and a model number of your choice (there's a .txt file with a bunch in it, and the ModelSniffer addon can help find more.)
Once you add it, it'll show up in the list above. You can change the model number and select 'Apply Model' to update it. No zoning required!

<img width="562" height="425" alt="image" src="https://github.com/user-attachments/assets/ca5bed25-eb44-4e0b-b5a2-8e44fe22d823" /> 

Other players can have unique pets, too. You may add these manually for each player, or you can import their pets. You can also export your pets for other's to use, too - and they'll see them in-game!

<img width="632" height="484" alt="image" src="https://github.com/user-attachments/assets/21672edc-641a-4701-95be-5c10b1d3e76b" />

When you Export anything, it will put the files into your UniquePets folder. When you import, it'll take from that same location.

Remember: ***Pet and Player names are case-sensitive!***


## Finding Model Numbers

I've included some model numbers I've tested in the ModelNumbersTested.txt folder that you can use, but you can also use the ModelSniffer.Lua addon to locate more. Warning: It's very verbose.

# About Animations and Models

![UniquePets](https://github.com/user-attachments/assets/80b2f48e-8475-4ab7-b69d-8c0efb792228)

You should know that there's no harm in replacing models for your characters or pets, but it *can* look funny if the pet and the model aren't well suited to each other. This is **most evident** on Avatars and their Bloodpacts. 

To help with this, I've added 'Animation Patching'.

<img width="673" height="782" alt="image" src="https://github.com/user-attachments/assets/92e3b33f-f6d9-4367-9e2b-964919a812e3" />
<img width="761" height="121" alt="image" src="https://github.com/user-attachments/assets/64666985-41a2-4624-ab84-0d15114e1b60" />



## Tips and Tricks
* If you know what you want to make your pet look like, use the ModelSniffer while near that creature in-game to get its model number, then use that for your model swap.
* With the addon loaded, use /addon reload UniquePets to quickly refresh it once you make a change in your Settings.Lua - Otherwise it won't show!

## Current Known Issues
* Sometimes when your pet is first summoned/called, it will briefly revert to its base model. This is because the game doesn't yet know you're their owner, and it'll update as soon as they move.
* Sometimes when your pet is released/dies, it will revert to its base model. This is due to the game forgetting you're the owner of the pet at that moment, and so the model is reverted.
