Demo app: Meet Jev

A small Sinatra app. The questions are editable in the page; the API key stays on the server.

Run
  cd demo_app
  bundle install
  export TYPESAFE_API_KEY=...
  bundle exec ruby app.rb
  open http://localhost:4567

For the room: run it on the laptop, share the address on the local network (http://<laptop ip>:4567),
everyone opens it in their browser. One key, server side. Nothing to install for them.

Pages
  /inbox         one email, four questions (spam noul, category choice, urgency score, needs_human noul)
  /trips         one trip record, one question (business noul), the "check" band between 35% and 65%
  /inbox/batch   20 audited sample emails through the four questions in one call, the triage table
  /trips/batch   same with 20 trips

The samples come from the audited datasets (status ok). Paste anything else in the textarea.
The take-home is jev_folder.rb at the root: same questions, your own folder, a CSV back.
