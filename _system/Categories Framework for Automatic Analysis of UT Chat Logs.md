



---

# UT99 Chat Classification Framework



---

# Overview

This framework classifies Unreal Tournament in-game chatter into operational categories that allow server admins to rapidly identify:

- Player complaints
    
- Technical/server issues
    
- Social interaction
    
- Suspicious behavior
    
- Toxicity
    
- Community-building moments
    
- Requests/help
    
- Strategy discussion
    
- Contact/link sharing
    
- Moderation-relevant incidents
    

The structure is designed for:

- Manual review
    
- Future machine-learning classification
    
- Keyword/regex pipelines
    
- Alert prioritization systems
    

---

# Primary Categories

## 1. Complaints

General frustration, dissatisfaction, balance complaints, gameplay irritation, or emotional venting.

### Subcategories

#### 1.1 Gameplay Frustration

Examples:

- “fucking hitscan bah i hate that”
    
- “dumb server”
    
- “combo noreg”
    

Comment:  
Often emotional rather than actionable.

---

#### 1.2 Performance Complaints

Examples:

- “game is so bugy again”
    
- “im shooting at air”
    
- “lag?”
    

Comment:  
Potential indicators of network, hitreg, tickrate, or newnet issues.

---

#### 1.3 Self-Deprecation / Skill Frustration

Examples:

- “i just suck at it”
    
- “fuck im old”
    
- “if i could aim i would be awesome”
    

Comment:  
Usually harmless social chatter.

---

# 2. Issues

Technical, gameplay, server, or connectivity problems.

### Subcategories

#### 2.1 Disconnects / Connectivity

Examples:

- “did u get disconnectred at end of game”
    
- “did you get disconnected?”
    

Comment:  
High-value for admins. Should likely trigger elevated review.

---

#### 2.2 Performance / Lag

Examples:

- “lag?”
    
- “combo noreg”
    
- “newnet for a month this shit feels weird”
    

Comment:  
Useful for tracking recurring netcode complaints.

---

#### 2.3 Client/System Problems

Examples:

- “audio issue”
    
- “pc is ass”
    

Comment:  
Not always server-related.

---

# 3. Requests

Players asking for help, changes, testing, or participation.

### Subcategories

#### 3.1 Gameplay Requests

Examples:

- “lets do some 2v2”
    
- “want to check it out?”
    

---

#### 3.2 Technical Assistance Requests

Examples:

- “can you help me test new version of RA for 5 mins”
    
- “please show me”
    

---

#### 3.3 Rescue / Immediate Help

Examples:

- “help”
    
- “i am in the pit”
    

Comment:  
Can indicate map exploit/stuck locations.

---

# 4. Compliments

Positive reinforcement, praise, admiration, or sportsmanship.

### Subcategories

#### 4.1 Skill Praise

Examples:

- “goddamn smellass is a fuckinG GOD AT THIS GAME”
    
- “nice games drew”
    

---

#### 4.2 Positive Reactions

Examples:

- “nice”
    
- “N1”
    
- “great map”
    

---

# 5. Notable (Suspicious Behavior / Admin Attention)

Potential cheating accusations, suspicious mechanics, abnormal behavior, or admin-interest events.

### Subcategories

#### 5.1 Cheating / Aimbot Accusations

Examples:

- “using aimbot in 2026?”
    

Comment:  
Very high-value category.

Recommended priority:  
HIGH

---

#### 5.2 Abnormal Gameplay Reactions

Examples:

- “SURVIVES A FULL SECONDARY”
    
- “how did u know snake”
    

Comment:  
May indicate:

- Lag compensation issues
    
- Prediction anomalies
    
- Wallhack suspicion
    
- Damage inconsistencies
    

---

#### 5.3 Trolling / Disruptive Play

Examples:

- “stop trolling in pubs”
    
- “join pug nerd”
    

Comment:  
Moderation relevance depends on repetition/severity.

---

# 6. Contact Info and Links

URLs, server addresses, external contact references, or recruitment-style messaging.

### Subcategories

#### 6.1 Server Promotion

Examples:

- “unreal://45.76.227.188:7777”
    

Comment:  
Very important automation category.

Potential uses:

- Detect server advertising
    
- Whitelist friendly communities
    
- Detect spam campaigns
    

---

#### 6.2 Recruitment / Invitations

Examples:

- “add to your favs”
    
- “maybe go there”
    

---

# 7. Strategy / Coaching

Gameplay instruction, tactics, mentoring, or mechanics explanation.

### Subcategories

#### 7.1 Tactical Advice

Examples:

- “get in their face”
    
- “takes away their advantage”
    

---

#### 7.2 Training / Mentorship

Examples:

- “there are some basic things you should do on a weekly basis”
    
- “keep practicing with it”
    

---

# 8. Social / Community Chatter

Non-actionable conversational interaction that helps measure community engagement.

### Subcategories

#### 8.1 Greetings / Casual Conversation

Examples:

- “hi dude”
    
- “good morning”
    

---

#### 8.2 Real-Life Discussion

Examples:

- “Mother's day stuff”
    
- “date night with the wifey”
    

---

# 9. Toxicity / Explicit Language

Profanity, insults, hostile language, or adult content.

### Subcategories

#### 9.1 Mild Toxicity

Examples:

- “damn u”
    
- “novice bot”
    

---

#### 9.2 Explicit / Adult Content

Examples:

- “Porn Studio?”
    
- sexual humor discussion
    

Comment:  
Should likely receive a moderation flag but lower severity than hate speech/threats.

---

# Recommended Severity Levels

|Severity|Meaning|
|---|---|
|LOW|Normal chatter|
|MEDIUM|Repeated complaints/issues|
|HIGH|Suspicious gameplay / cheating accusations|
|CRITICAL|Threats, doxxing, slurs, targeted harassment|

---




